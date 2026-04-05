import SwiftUI

/// `@main` marks the single process entry point for a Swift app.
@main
struct matcha_appApp: App {
    /// Bridges old-style AppKit lifecycle callbacks into a SwiftUI app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                permissionManager: appDelegate.permissionManager,
                runtimeModel: appDelegate.runtimeModel,
                focusModel: appDelegate.focusModel,
                suggestionModel: appDelegate.suggestionModel
            )
        } label: {
            MenuBarStatusLabelView(
                focusModel: appDelegate.focusModel
            )
        }
        .menuBarExtraStyle(.window)
    }
}
