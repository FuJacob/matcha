import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// File overview:
/// Polls and exposes the two system permissions Matcha depends on: Accessibility for reading
/// focus state and Input Monitoring for global key capture.
///
/// `@MainActor` guarantees permission state is mutated on the UI thread.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false

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

    /// Re-reads the current system permission state and republishes any changes to observers.
    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    /// Opens System Settings directly to the Accessibility pane so the user can grant access.
    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    /// Opens System Settings directly to the Input Monitoring pane so the user can grant access.
    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        )
    }
}
