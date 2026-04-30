import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Observes Accessibility focus notifications and publishes the latest `FocusSnapshot`.
///
/// This experimental version removes the polling timer entirely. `FocusTracker` owns observer
/// lifecycle, permission/frontmost-app guards, and the final `snapshot` publication contract.
/// AX candidate resolution lives in `FocusSnapshotResolver`, and caret/frame heuristics live in
/// `AXTextGeometryResolver`.
nonisolated private let focusTrackerObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else {
        return
    }

    let notificationName = notification as String
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        tracker.handleAXNotification(named: notificationName)
    }
}

@MainActor
final class FocusTracker {
    private enum AXNotificationSet {
        static let application: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXApplicationDeactivatedNotification as CFString
        ]

        static let focusedElement: [CFString] = [
            kAXValueChangedNotification as CFString,
            kAXSelectedTextChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString
        ]
    }

    var onSnapshotChange: ((FocusSnapshot) -> Void)?
    /// Debug hook for raw AX notification hits. The tracker still publishes snapshots separately
    /// because several notifications can collapse into the same resolved focus state.
    var onAXNotification: ((String) -> Void)?

    private(set) var snapshot: FocusSnapshot = .inactive {
        didSet {
            onSnapshotChange?(snapshot)
        }
    }

    private let permissionProvider: @MainActor () -> Bool
    private let ignoredBundleIdentifier: String?
    private let snapshotResolver: FocusSnapshotResolver

    private var observer: AXObserver?
    private var observedApplicationElement: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var observedApplicationPID: pid_t?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var scheduledRefreshTask: Task<Void, Never>?

    init(
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        snapshotResolver: FocusSnapshotResolver? = nil
    ) {
        self.permissionProvider = permissionProvider
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        // Default resolver construction must happen inside the actor-isolated initializer body.
        // Swift evaluates default parameter expressions before entering the `@MainActor` context.
        self.snapshotResolver = snapshotResolver ?? FocusSnapshotResolver()
    }

    /// Starts event-driven AX observation and immediately captures an initial snapshot.
    func start() {
        guard workspaceActivationObserver == nil else {
            refreshNow()
            return
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }

        refreshNow()
    }

    /// Stops event observation while leaving the most recent snapshot available to callers.
    func stop() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }

        clearAXObserver()
    }

    /// Performs a synchronous snapshot capture outside the normal notification cadence.
    func refreshNow() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        let capture = captureSnapshot()
        snapshot = capture.snapshot

        if let focusedElement = capture.focusedElement {
            registerFocusedElementNotifications(on: focusedElement)
        } else {
            clearFocusedElementNotifications()
        }
    }

    fileprivate func handleAXNotification(named notificationName: String) {
        onAXNotification?(notificationName)

        if notificationName == kAXApplicationDeactivatedNotification as String {
            scheduleRefresh(after: 0)
            return
        }

        // AX notifications can fire before the app has updated value/selection attributes.
        // A tiny coalescing delay avoids reading the old state while still feeling immediate.
        scheduleRefresh(after: 0.005)
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { [weak self] in
            guard delay > 0 else {
                self?.refreshNow()
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }

            self?.refreshNow()
        }
    }

    /// Captures the current frontmost application's focused element and reduces it into a snapshot.
    private func captureSnapshot() -> FocusCaptureResult {
        guard permissionProvider() else {
            clearAXObserver()
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: "Accessibility permission missing",
                    bundleIdentifier: nil,
                    capability: .blocked("Accessibility permission is required."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            clearAXObserver()
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: "No active application",
                    bundleIdentifier: nil,
                    capability: .unsupported("No active application."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        if application.bundleIdentifier == ignoredBundleIdentifier {
            clearAXObserver()
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: application.localizedName ?? "Tabby",
                    bundleIdentifier: application.bundleIdentifier,
                    capability: .blocked("Tabby is focused."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        configureAXObserver(for: application)

        guard let focusedElement = AXHelper.focusedElement() else {
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: application.localizedName ?? "Unknown",
                    bundleIdentifier: application.bundleIdentifier,
                    capability: .unsupported("No focused Accessibility element."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        return FocusCaptureResult(
            snapshot: snapshotResolver.resolveSnapshot(
                focusedElement: focusedElement,
                application: application
            ),
            focusedElement: focusedElement
        )
    }

    private func configureAXObserver(for application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard observer == nil || observedApplicationPID != pid else {
            return
        }

        clearAXObserver()

        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, focusTrackerObserverCallback, &newObserver)
        guard result == .success, let newObserver else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        observer = newObserver
        observedApplicationElement = applicationElement
        observedApplicationPID = pid

        let source = AXObserverGetRunLoopSource(newObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        for notification in AXNotificationSet.application {
            addNotification(notification, to: applicationElement)
        }
    }

    private func registerFocusedElementNotifications(on focusedElement: AXUIElement) {
        guard observer != nil else {
            return
        }

        if let observedFocusedElement,
           AXHelper.elementIdentity(for: observedFocusedElement) == AXHelper.elementIdentity(for: focusedElement) {
            return
        }

        clearFocusedElementNotifications()
        observedFocusedElement = focusedElement

        for notification in AXNotificationSet.focusedElement {
            addNotification(notification, to: focusedElement)
        }
    }

    private func clearFocusedElementNotifications() {
        guard let observer, let observedFocusedElement else {
            self.observedFocusedElement = nil
            return
        }

        for notification in AXNotificationSet.focusedElement {
            AXObserverRemoveNotification(observer, observedFocusedElement, notification)
        }

        self.observedFocusedElement = nil
    }

    private func clearAXObserver() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        clearFocusedElementNotifications()

        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        observer = nil
        observedApplicationElement = nil
        observedApplicationPID = nil
    }

    @discardableResult
    private func addNotification(_ notification: CFString, to element: AXUIElement) -> Bool {
        guard let observer else {
            return false
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, element, notification, refcon)
        return result == .success || result == .notificationAlreadyRegistered
    }
}

private struct FocusCaptureResult {
    let snapshot: FocusSnapshot
    let focusedElement: AXUIElement?

    init(snapshot: FocusSnapshot, focusedElement: AXUIElement? = nil) {
        self.snapshot = snapshot
        self.focusedElement = focusedElement
    }
}
