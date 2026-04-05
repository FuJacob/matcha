import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Polls the Accessibility tree, gathers nearby candidate elements, and reduces them into one
/// stable `FocusSnapshot`. This is the boundary where raw AX data becomes app-friendly focus state.
///
private struct AXFocusCandidate {
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let textValue: String?
    let selection: NSRange?
    let caretRect: CGRect?
    let isSecure: Bool
    let resolverCandidate: FocusCapabilityCandidate
}

/// Polls the current AX focus and reduces it into a stable snapshot.
/// Polling is intentionally simple here: every tick recomputes truth from the OS.
@MainActor
final class FocusTracker {
    var onSnapshotChange: ((FocusSnapshot) -> Void)?

    private(set) var snapshot: FocusSnapshot = .inactive {
        didSet {
            onSnapshotChange?(snapshot)
        }
    }

    private let pollInterval: TimeInterval
    private let permissionProvider: @MainActor () -> Bool
    private let ignoredBundleIdentifier: String?

    private var timer: Timer?

    init(
        pollInterval: TimeInterval,
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?
    ) {
        self.pollInterval = pollInterval
        self.permissionProvider = permissionProvider
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
    }

    /// Starts periodic AX polling and immediately captures an initial snapshot.
    func start() {
        guard timer == nil else {
            refreshNow()
            return
        }

        refreshNow()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops polling while leaving the most recent snapshot available to callers.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Performs a synchronous snapshot capture outside the normal polling cadence.
    func refreshNow() {
        snapshot = captureSnapshot()
    }

    /// Captures the current frontmost application's focused element and reduces it into a snapshot.
    private func captureSnapshot() -> FocusSnapshot {
        guard permissionProvider() else {
            return FocusSnapshot(
                applicationName: "Accessibility permission missing",
                bundleIdentifier: nil,
                capability: .blocked("Accessibility permission is required."),
                context: nil,
                inspection: nil
            )
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            return FocusSnapshot(
                applicationName: "No active application",
                bundleIdentifier: nil,
                capability: .unsupported("No active application."),
                context: nil,
                inspection: nil
            )
        }

        if application.bundleIdentifier == ignoredBundleIdentifier {
            return FocusSnapshot(
                applicationName: application.localizedName ?? "Matcha",
                bundleIdentifier: application.bundleIdentifier,
                capability: .blocked("Matcha is focused."),
                context: nil,
                inspection: nil
            )
        }

        guard let element = AXHelper.focusedElement() else {
            return FocusSnapshot(
                applicationName: application.localizedName ?? "Unknown",
                bundleIdentifier: application.bundleIdentifier,
                capability: .unsupported("No focused Accessibility element."),
                context: nil,
                inspection: nil
            )
        }

        return snapshot(for: element, application: application)
    }

    /// Resolves the best editable candidate around the focused AX node and materializes a focus snapshot.
    private func snapshot(for focusedElement: AXUIElement, application: NSRunningApplication) -> FocusSnapshot {
        let applicationName = application.localizedName ?? "Unknown"
        let bundleIdentifier = application.bundleIdentifier ?? "unknown.bundle"
        let focusedRole = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: focusedElement) ?? "Unknown"
        let focusedSubrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: focusedElement)
        let focusedElementIdentifier = AXHelper.elementIdentifier(for: focusedElement, bundleIdentifier: bundleIdentifier)

        let candidates = candidateElements(around: focusedElement).map {
            candidateSnapshot(for: $0, bundleIdentifier: bundleIdentifier)
        }
        let resolution = FocusCapabilityResolver.resolve(candidates: candidates.map(\.resolverCandidate))
        let selectedCandidate = resolution.bestDiagnosticCandidate.flatMap { candidate in
            candidates.first(where: { $0.elementIdentifier == candidate.elementIdentifier })
        }
        let inspection = FocusInspectionSnapshot(
            focusedElementIdentifier: focusedElementIdentifier,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            resolvedElementIdentifier: selectedCandidate?.elementIdentifier,
            resolvedRole: selectedCandidate?.role,
            resolvedSubrole: selectedCandidate?.subrole,
            missingCapabilities: resolution.resolvedCandidate == nil ? resolution.missingCapabilities : []
        )

        guard let resolvedCandidate = selectedCandidate,
              resolution.resolvedCandidate != nil
        else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported(resolution.unsupportedReason),
                context: nil,
                inspection: inspection
            )
        }

        guard let selection = resolvedCandidate.selection else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        guard selection.location >= 0, selection.length >= 0 else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is invalid."),
                context: nil,
                inspection: inspection
            )
        }

        let value = resolvedCandidate.textValue ?? ""
        guard selection.location <= value.utf16.count else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range exceeds the current field value."),
                context: nil,
                inspection: inspection
            )
        }

        guard let caretRect = resolvedCandidate.caretRect else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Caret bounds are unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        let nsValue = value as NSString
        let safeSelectionLocation = min(selection.location, nsValue.length)
        let trailingStart = min(selection.location + selection.length, nsValue.length)
        let context = FocusedInputSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            elementIdentifier: resolvedCandidate.elementIdentifier,
            role: resolvedCandidate.role,
            subrole: resolvedCandidate.subrole,
            caretRect: caretRect,
            precedingText: nsValue.substring(to: safeSelectionLocation),
            trailingText: nsValue.substring(from: trailingStart),
            selection: selection,
            isSecure: resolvedCandidate.isSecure
        )

        if resolvedCandidate.isSecure {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Secure text input is active."),
                context: context,
                inspection: inspection
            )
        }

        if selection.length > 0 {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Text is currently selected."),
                context: context,
                inspection: inspection
            )
        }

        return FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: .supported,
            context: context,
            inspection: inspection
        )
    }

    private func candidateElements(around focusedElement: AXUIElement) -> [AXUIElement] {
        var ordered: [AXUIElement] = []
        var seen = Set<String>()

        func append(_ element: AXUIElement?) {
            guard let element else {
                return
            }

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else {
                return
            }

            ordered.append(element)
        }

        append(focusedElement)

        var ancestors: [AXUIElement] = []
        var currentElement = focusedElement
        for _ in 0 ..< 2 {
            guard let parent = AXHelper.parentElement(of: currentElement) else {
                break
            }

            ancestors.append(parent)
            append(parent)
            currentElement = parent
        }

        for node in [focusedElement] + ancestors {
            for child in AXHelper.childElements(of: node) {
                append(child)
            }
        }

        return ordered
    }

    /// Extracts the AX properties Matcha needs from one candidate element near the current focus.
    private func candidateSnapshot(for element: AXUIElement, bundleIdentifier: String) -> AXFocusCandidate {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let supportedAttributes = Set(AXHelper.attributeNames(on: element))
        let supportedParameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))
        let explicitEditableFlag = supportedAttributes.contains("AXEditable")
            ? AXHelper.boolValue(for: "AXEditable" as CFString, on: element)
            : nil
        let textValue = supportedAttributes.contains(kAXValueAttribute as String)
            ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            : nil
        let selection = supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
            ? AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
            : nil
        let caretRect = selection.flatMap {
            resolveCaretRect(
                for: element,
                selection: $0,
                supportsBoundsForRange: supportedParameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String),
                supportsFrame: supportedAttributes.contains("AXFrame"),
                bundleIdentifier: bundleIdentifier
            )
        }
        let isSecure = isSecureElement(element: element, role: role, subrole: subrole)
        let elementIdentifier = AXHelper.elementIdentifier(for: element, bundleIdentifier: bundleIdentifier)
        let resolverCandidate = FocusCapabilityCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            editableHintScore: AXHelper.editabilityHintScore(role: role, explicitEditableFlag: explicitEditableFlag),
            hasStrongEditabilitySignal: AXHelper.hasStrongEditabilitySignal(role: role, explicitEditableFlag: explicitEditableFlag),
            isKnownReadOnlyRole: AXHelper.isKnownReadOnlyRole(role),
            hasTextValue: textValue != nil,
            hasSelectionRange: selection != nil,
            hasCaretBounds: caretRect != nil,
            isSecure: isSecure
        )

        return AXFocusCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            textValue: textValue,
            selection: selection,
            caretRect: caretRect,
            isSecure: isSecure,
            resolverCandidate: resolverCandidate
        )
    }

    /// Finds the best caret anchor available, preferring bounds-for-range and falling back to element frame.
    private func resolveCaretRect(
        for element: AXUIElement,
        selection: NSRange,
        supportsBoundsForRange: Bool,
        supportsFrame: Bool,
        bundleIdentifier: String
    ) -> CGRect? {
        if supportsBoundsForRange,
           let rect = AXHelper.parameterizedRectValue(
               for: kAXBoundsForRangeParameterizedAttribute as CFString,
               range: NSRange(location: selection.location, length: 0),
               on: element
           ), !rect.isEmpty {
            return AXHelper.cocoaRect(
                fromAccessibilityRect: rect,
                bundleIdentifier: bundleIdentifier,
                isTextRect: true
            )
        }

        if supportsBoundsForRange,
           selection.location > 0,
           let rect = AXHelper.parameterizedRectValue(
               for: kAXBoundsForRangeParameterizedAttribute as CFString,
               range: NSRange(location: selection.location - 1, length: 1),
               on: element
           ), !rect.isEmpty {
            let cocoaRect = AXHelper.cocoaRect(fromAccessibilityRect: rect, bundleIdentifier: bundleIdentifier, isTextRect: true)
            return CGRect(x: cocoaRect.maxX, y: cocoaRect.minY, width: 2, height: cocoaRect.height)
        }

        if supportsFrame,
           let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element), !frame.isEmpty {
            return AXHelper.cocoaRect(fromAccessibilityRect: frame, bundleIdentifier: bundleIdentifier, isTextRect: false)
        }

        return nil
    }

    /// Detects secure inputs so Matcha can intentionally refuse to operate in sensitive fields.
    private func isSecureElement(element: AXUIElement, role: String, subrole: String?) -> Bool {
        let secureMarkers = [
            role.lowercased(),
            subrole?.lowercased() ?? "",
            AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)?.lowercased() ?? "",
            AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element)?.lowercased() ?? "",
        ]

        return secureMarkers.contains { marker in
            marker.contains("secure") || marker.contains("password")
        }
    }
}
