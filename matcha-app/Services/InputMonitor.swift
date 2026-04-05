import ApplicationServices
import Foundation

/// Only the event categories needed for typing-triggered prediction are modeled here.
struct CapturedInputEvent: Equatable {
    enum Kind: String, Equatable {
        case textMutation
        case navigation
        case shortcutMutation
        case dismissal
        case other
    }

    let kind: Kind
    let keyCode: CGKeyCode
    let characters: String
    let flags: CGEventFlags

    var shouldSchedulePrediction: Bool {
        switch kind {
        case .textMutation, .shortcutMutation:
            return true
        default:
            return false
        }
    }

    var shouldClearSuggestion: Bool {
        switch kind {
        case .textMutation, .navigation, .shortcutMutation, .dismissal:
            return true
        case .other:
            return false
        }
    }
}

/// Installs a listen-only session event tap.
/// We observe typing here, but we do not intercept or mutate host app input in this slice.
@MainActor
final class InputMonitor {
    var onEvent: ((CapturedInputEvent) -> Void)?
    var onTapStateChange: ((Bool) -> Void)?

    private let permissionProvider: @MainActor () -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(permissionProvider: @escaping @MainActor () -> Bool) {
        self.permissionProvider = permissionProvider
    }

    func start() {
        refresh()
    }

    func stop() {
        destroyTap()
    }

    func refresh() {
        if permissionProvider() {
            installTapIfNeeded()
        } else {
            destroyTap()
        }
    }

    private func installTapIfNeeded() {
        guard eventTap == nil else {
            onTapStateChange?(true)
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                monitor.handleTap(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            onTapStateChange?(false)
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        onTapStateChange?(true)
    }

    private func destroyTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        runLoopSource = nil

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
        onTapStateChange?(false)
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            onEvent?(classify(event: event))
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func classify(event: CGEvent) -> CapturedInputEvent {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let characters = event.unicodeString

        // We classify events by behavior instead of raw key codes alone.
        // That keeps the prediction layer coupled to "what happened" rather than "which key fired."
        if [123, 124, 125, 126].contains(keyCode) {
            return CapturedInputEvent(kind: .navigation, keyCode: keyCode, characters: characters, flags: flags)
        }

        if [51, 117, 36, 76].contains(keyCode) {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags)
        }

        if keyCode == 53 {
            return CapturedInputEvent(kind: .dismissal, keyCode: keyCode, characters: characters, flags: flags)
        }

        if flags.contains(.maskCommand) {
            let mutationShortcutKeyCodes: Set<CGKeyCode> = [0, 6, 7, 9]
            let kind: CapturedInputEvent.Kind = mutationShortcutKeyCodes.contains(keyCode) ? .shortcutMutation : .dismissal
            return CapturedInputEvent(kind: kind, keyCode: keyCode, characters: characters, flags: flags)
        }

        if !characters.trimmingCharacters(in: .controlCharacters).isEmpty {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags)
        }

        return CapturedInputEvent(kind: .other, keyCode: keyCode, characters: characters, flags: flags)
    }
}

private extension CGEvent {
    var unicodeString: String {
        var length: Int = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return ""
        }

        // Core Graphics fills a caller-provided UTF-16 buffer here, so we allocate manually and
        // then construct a Swift String from those code units.
        let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: length)
        defer {
            buffer.deallocate()
        }

        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
