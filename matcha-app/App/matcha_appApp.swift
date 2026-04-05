import SwiftUI

/// `@main` marks the single process entry point for a Swift app.
@main
struct matcha_appApp: App {
    /// Bridges old-style AppKit lifecycle callbacks into a SwiftUI app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(runtimeModel: appDelegate.runtimeModel)
        } label: {
            Image(systemName: appDelegate.runtimeModel.menuBarIconName)
        }
        .menuBarExtraStyle(.window)
    }
}
