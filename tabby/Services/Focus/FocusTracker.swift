import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Polls the Accessibility tree on a timer and publishes the latest `FocusSnapshot`.
///
/// This file is now intentionally small: it owns poll timing, permission/frontmost-app guards, and
/// the final `snapshot` publication contract. AX candidate resolution lives in
/// `FocusSnapshotResolver`, and caret/frame heuristics live in `AXTextGeometryResolver`.
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
    private let snapshotResolver: FocusSnapshotResolver

    private var timer: Timer?

    init(
        pollInterval: TimeInterval,
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        snapshotResolver: FocusSnapshotResolver? = nil
    ) {
        self.pollInterval = pollInterval
        self.permissionProvider = permissionProvider
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        // Default resolver construction must happen inside the actor-isolated initializer body.
        // Swift evaluates default parameter expressions before entering the `@MainActor` context.
        self.snapshotResolver = snapshotResolver ?? FocusSnapshotResolver()
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
                applicationName: application.localizedName ?? "Tabby",
                bundleIdentifier: application.bundleIdentifier,
                capability: .blocked("Tabby is focused."),
                context: nil,
                inspection: nil
            )
        }

        guard let focusedElement = AXHelper.focusedElement() else {
            return FocusSnapshot(
                applicationName: application.localizedName ?? "Unknown",
                bundleIdentifier: application.bundleIdentifier,
                capability: .unsupported("No focused Accessibility element."),
                context: nil,
                inspection: nil
            )
        }

        return snapshotResolver.resolveSnapshot(
            focusedElement: focusedElement,
            application: application
        )
    }
}
