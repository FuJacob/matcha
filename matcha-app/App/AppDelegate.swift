import AppKit
import Combine

/// App lifecycle callbacks happen on the main thread; marking this type clarifies actor expectations.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionManager: PermissionManager
    let serverManager: LlamaServerManager
    let runtimeModel: RuntimeBootstrapModel
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let suggestionModel: SuggestionDebugModel

    private var cancellables = Set<AnyCancellable>()

    override init() {
        let permissionManager = PermissionManager()
        let serverManager = LlamaServerManager()
        let inputMonitor = InputMonitor(permissionProvider: { permissionManager.inputMonitoringGranted })
        let focusModel = FocusTrackingModel(
            pollInterval: 0.25,
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier
        )
        let runtimeModel = RuntimeBootstrapModel(serverManager: serverManager)
        let suggestionModel = SuggestionDebugModel(
            permissionManager: permissionManager,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            completionClient: LlamaCompletionClient(serverManager: serverManager),
            contextBuffer: ContextBuffer(),
            configuration: .debugDefaults
        )

        self.permissionManager = permissionManager
        self.serverManager = serverManager
        self.runtimeModel = runtimeModel
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.suggestionModel = suggestionModel
        super.init()

        permissionManager.$inputMonitoringGranted
            .sink { [weak self] _ in
                self?.inputMonitor.refresh()
            }
            .store(in: &cancellables)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeModel.startIfNeeded()
        focusModel.start()
        inputMonitor.start()
        suggestionModel.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        suggestionModel.stop()
        inputMonitor.stop()
        focusModel.stop()
        runtimeModel.stop()
    }
}
