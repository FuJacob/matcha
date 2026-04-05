import AppKit
import SwiftUI

/// File overview:
/// Owns the first-run welcome experience. This type persists whether onboarding has already been
/// shown and manages the one compact AppKit window that hosts the SwiftUI welcome content.
///
/// We keep this in `App/` instead of `UI/` because it owns lifecycle and persistence, not just
/// rendering. In React terms, this is a tiny controller/store plus a window host.
@MainActor
final class WelcomeCoordinator: NSObject, NSWindowDelegate {
    private let permissionManager: PermissionManager
    private let userDefaults: UserDefaults

    private var windowController: NSWindowController?

    private static let hasShownWelcomeDefaultsKey = "hasShownWelcomeWindow"

    init(
        permissionManager: PermissionManager,
        userDefaults: UserDefaults = .standard
    ) {
        self.permissionManager = permissionManager
        self.userDefaults = userDefaults
    }

    /// Presents the welcome UI once for the lifetime of this installation.
    /// The "shown" bit is persisted at presentation time so first-run onboarding stays one-time
    /// even if the user simply closes the window instead of pressing the button.
    func presentIfNeeded() {
        guard !userDefaults.bool(forKey: Self.hasShownWelcomeDefaultsKey) else {
            return
        }

        userDefaults.set(true, forKey: Self.hasShownWelcomeDefaultsKey)
        showWelcome()
    }

    /// Manual entry point for reopening the welcome screen later from the menu.
    func showWelcome() {
        if let window = windowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: WelcomeView(
                permissionManager: permissionManager,
                onDismiss: { [weak self] in
                    self?.dismissWelcome()
                },
                onOpenAccessibility: { [weak permissionManager] in
                    permissionManager?.openAccessibilitySettings()
                },
                onOpenInputMonitoring: { [weak permissionManager] in
                    permissionManager?.openInputMonitoringSettings()
                }
            )
        )

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 332),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Tabby"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        self.windowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
    }

    private func dismissWelcome() {
        windowController?.close()
    }
}
