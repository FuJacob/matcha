import AppKit

/// App lifecycle callbacks happen on the main thread; marking this type clarifies actor expectations.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let focusModel: FocusTrackingModel

    override init() {
        let permissionManager = PermissionManager()
        self.permissionManager = permissionManager
        runtimeModel = RuntimeBootstrapModel()
        focusModel = FocusTrackingModel(
            pollInterval: 0.25,
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeModel.startIfNeeded()
        focusModel.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeModel.stop()
        focusModel.stop()
    }
}
