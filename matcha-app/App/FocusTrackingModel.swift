import Combine
import Foundation

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

    func start() {
        guard !isStarted else {
            tracker.refreshNow()
            return
        }

        isStarted = true
        tracker.start()
    }

    func stop() {
        isStarted = false
        tracker.stop()
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
