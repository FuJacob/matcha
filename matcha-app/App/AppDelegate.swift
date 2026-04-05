import AppKit
import Combine

/// File overview:
/// Builds Matcha's dependency graph and starts the long-lived services that power
/// permissions, focus tracking, suggestion generation, overlay rendering, and acceptance.
/// This file is the app's composition root.
///
/// App lifecycle callbacks happen on the main thread; marking this type clarifies actor expectations.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator

    private let activationIndicatorController: ActivationIndicatorController
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let permissionManager = PermissionManager()
        let runtimeManager = LlamaRuntimeManager()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        let focusModel = FocusTrackingModel(
            pollInterval: 0.25,
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier
        )
        let welcomeCoordinator = WelcomeCoordinator(permissionManager: permissionManager)
        let runtimeModel = RuntimeBootstrapModel(runtimeManager: runtimeManager)
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        let overlayController = OverlayController()
        let activationIndicatorController = ActivationIndicatorController()
        let screenshotContextGenerator = ScreenshotContextGenerator(runtimeManager: runtimeManager)
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: suggestionInserter,
            suggestionEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager),
            screenshotContextGenerator: screenshotContextGenerator,
            contextBuffer: ContextBuffer(),
            configuration: .debugDefaults
        )

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.suggestionCoordinator = suggestionCoordinator
        self.welcomeCoordinator = welcomeCoordinator
        self.activationIndicatorController = activationIndicatorController
        super.init()

        runtimeModel.onWillReloadModel = { [weak suggestionCoordinator] in
            suggestionCoordinator?.prepareForRuntimeModelSwitch()
        }

        permissionManager.$inputMonitoringGranted
            .sink { [weak self] _ in
                self?.inputMonitor.refresh()
            }
            .store(in: &cancellables)

        focusModel.$snapshot
            .sink { [weak self] snapshot in
                self?.updateActivationIndicator(for: snapshot)
            }
            .store(in: &cancellables)

        suggestionCoordinator.$visualContextStatus
            .sink { [weak self] status in
                self?.activationIndicatorController.setVisualContextStatus(status)
            }
            .store(in: &cancellables)
    }

    /// Starts runtime and observer services once AppKit reports that app launch finished.
    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeModel.startIfNeeded()
        focusModel.start()
        inputMonitor.start()
        suggestionCoordinator.start()
        welcomeCoordinator.presentIfNeeded()
    }

    /// Stops long-lived services before process exit so observers and runtime resources detach cleanly.
    func applicationWillTerminate(_ notification: Notification) {
        activationIndicatorController.hide(reason: "Activation indicator hidden because Matcha is terminating.")
        suggestionCoordinator.stop()
        inputMonitor.stop()
        focusModel.stop()
        runtimeModel.stop()
    }

    /// Mirrors supported-focus state into the small outside-left activation indicator.
    private func updateActivationIndicator(for snapshot: FocusSnapshot) {
        guard case .supported = snapshot.capability,
              let inputFrameRect = snapshot.context?.inputFrameRect
        else {
            activationIndicatorController.hide(reason: "Activation indicator hidden because the current field is not supported.")
            return
        }

        activationIndicatorController.show(at: inputFrameRect)
    }
}
