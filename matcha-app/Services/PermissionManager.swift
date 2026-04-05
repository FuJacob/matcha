import AppKit
import ApplicationServices
import Combine

/// `@MainActor` guarantees permission state is mutated on the UI thread.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false

    private var pollTimer: Timer?

    /// Polling keeps UI state aligned with system settings changes performed outside the app.
    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}
