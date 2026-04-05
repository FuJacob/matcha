import AppKit

/// App lifecycle callbacks happen on the main thread; marking this type clarifies actor expectations.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtimeModel = RuntimeBootstrapModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeModel.startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeModel.stop()
    }
}
