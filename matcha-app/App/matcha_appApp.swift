import SwiftUI

/// File overview:
/// Declares the SwiftUI app entry point and hosts the single menu-bar scene that renders
/// Matcha's compact status UI. Shared services are injected through `AppDelegate`.
///
/// `@main` marks the single process entry point for a Swift app.
@main
struct matcha_appApp: App {
    /// Bridges old-style AppKit lifecycle callbacks into a SwiftUI app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Defines the menu bar extra that surfaces Matcha's runtime, focus, and suggestion state.
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                permissionManager: appDelegate.permissionManager,
                runtimeModel: appDelegate.runtimeModel,
                focusModel: appDelegate.focusModel,
                suggestionCoordinator: appDelegate.suggestionCoordinator
            )
        } label: {
            MenuBarStatusLabelView(
                focusModel: appDelegate.focusModel
            )
        }
        .menuBarExtraStyle(.window)
    }
}
