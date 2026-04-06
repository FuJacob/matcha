import Combine
import Foundation

/// File overview:
/// Publishes focused-input snapshots to SwiftUI and other main-actor consumers. It keeps
/// AX polling details hidden behind a small observable interface.
///
/// Bridges the polling tracker into SwiftUI-facing published state.
@MainActor
final class FocusTrackingModel: ObservableObject {
    @Published private(set) var snapshot: FocusSnapshot

    private let tracker: FocusTracker
    private var isStarted = false

    init(
        pollInterval: TimeInterval,
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?
    ) {
        tracker = FocusTracker(
            pollInterval: pollInterval,
            permissionProvider: permissionProvider,
            ignoredBundleIdentifier: ignoredBundleIdentifier
        )
        snapshot = tracker.snapshot

        tracker.onSnapshotChange = { [weak self] snapshot in
            self?.snapshot = snapshot
        }
    }

    /// Starts focus polling once and treats later calls as a request for an immediate refresh.
    func start() {
        guard !isStarted else {
            tracker.refreshNow()
            return
        }

        isStarted = true
        tracker.start()
    }

    /// Stops polling while leaving the last captured snapshot available for UI consumers.
    func stop() {
        isStarted = false
        tracker.stop()
    }

    /// A manual refresh is useful when another subsystem already knows "input just changed"
    /// and wants the latest AX snapshot immediately instead of waiting for the poll timer.
    func refreshNow() {
        tracker.refreshNow()
    }

    /// The menu bar needs a compact status string, not the full diagnostic reason.
    var menuBarStatusText: String {
        snapshot.capability.shortLabel
    }

    var menuBarSymbolName: String {
        switch snapshot.capability {
        case .supported:
            return "checkmark.circle"
        case .blocked:
            return "hand.raised.circle"
        case .unsupported:
            return "xmark.circle"
        }
    }
}
