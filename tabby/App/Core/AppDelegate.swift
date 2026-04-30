import AppKit
import Combine

/// File overview:
/// Starts the long-lived services that power permissions, focus tracking, suggestion generation,
/// overlay rendering, acceptance, and app updates. Dependency construction now lives in
/// `TabbyAppEnvironment`, while `AppDelegate` focuses on lifecycle wiring and cross-subsystem
/// subscriptions.
///
/// In React terms, this is the top-level container that owns the long-lived stores/services.
/// SwiftUI renders views from these objects, but the view layer does not create or own them.
///
/// App lifecycle callbacks happen on the main thread; marking this type clarifies actor expectations.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let appUpdateManager: AppUpdateManager
    let launchAtLoginService: LaunchAtLoginService
    let suggestionSettings: SuggestionSettingsModel
    let developerDiagnostics: DeveloperDiagnosticsModel
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator
    let settingsCoordinator: SettingsCoordinator

    private let activationIndicatorController: ActivationIndicatorController
    private let focusDebugOverlayController: FocusDebugOverlayController?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        // Build the dependency graph once up front so every scene/view observes the same
        // long-lived objects for the entire app session. `TabbyAppEnvironment` is a composition
        // helper here; the app delegate retains the root objects it needs directly.
        let environment = TabbyAppEnvironment()
        permissionManager = environment.permissionManager
        runtimeModel = environment.runtimeModel
        modelDownloadManager = environment.modelDownloadManager
        focusModel = environment.focusModel
        inputMonitor = environment.inputMonitor
        appUpdateManager = environment.appUpdateManager
        launchAtLoginService = environment.launchAtLoginService
        suggestionSettings = environment.suggestionSettings
        developerDiagnostics = environment.developerDiagnostics
        foundationModelAvailabilityService = environment.foundationModelAvailabilityService
        suggestionCoordinator = environment.suggestionCoordinator
        welcomeCoordinator = environment.welcomeCoordinator
        settingsCoordinator = environment.settingsCoordinator
        activationIndicatorController = environment.activationIndicatorController
        focusDebugOverlayController = environment.focusDebugOverlayController
        super.init()

        // These closures bridge events across subsystems without forcing those subsystems
        // to know about each other directly.
        runtimeModel.onWillReloadModel = { [weak suggestionCoordinator] in
            suggestionCoordinator?.prepareForRuntimeModelSwitch()
        }

        modelDownloadManager.onModelDirectoryChanged = { [weak self] in
            self?.handleModelDirectoryChange()
        }

        // Combine subscriptions keep the app's long-lived services in sync as permission and
        // focus state changes over time.
        permissionManager.$inputMonitoringGranted
            .sink { [weak self] _ in
                self?.inputMonitor.refresh()
            }
            .store(in: &cancellables)

        suggestionSettings.$selectedEngine
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.startRuntimeIfPreferredEngineRequiresIt()
            }
            .store(in: &cancellables)

        focusModel.$snapshot
            .sink { [weak self] snapshot in
                self?.updateActivationIndicator(for: snapshot)
                self?.updateDeveloperDiagnosticsOverlay()
            }
            .store(in: &cancellables)

        focusModel.$latestObserverEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                self?.developerDiagnostics.record(
                    stage: .axObserver,
                    status: .succeeded,
                    message: event.displayName,
                    metadata: ["sequence": String(event.sequence)]
                )
                self?.updateDeveloperDiagnosticsOverlay()
                self?.focusDebugOverlayController?.flashAXObserverHit()
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            developerDiagnostics.$overlaysEnabled.map { _ in () }.eraseToAnyPublisher(),
            developerDiagnostics.$loggingEnabled.map { _ in () }.eraseToAnyPublisher(),
            developerDiagnostics.$recentEvents.map { _ in () }.eraseToAnyPublisher(),
            developerDiagnostics.$contextPipelineItem.map { _ in () }.eraseToAnyPublisher(),
            developerDiagnostics.$completionPipelineItems.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$selectedEngine.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$selectedWordCountPreset.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$selectedIndicatorMode.map { _ in () }.eraseToAnyPublisher(),
            runtimeModel.$state.map { _ in () }.eraseToAnyPublisher(),
            runtimeModel.$selectedModelFilename.map { _ in () }.eraseToAnyPublisher(),
            suggestionCoordinator.$state.map { _ in () }.eraseToAnyPublisher(),
            suggestionCoordinator.$latestGenerationNumber.map { _ in () }.eraseToAnyPublisher(),
            suggestionCoordinator.$visualContextStatus.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in
            self?.updateDeveloperDiagnosticsOverlay()
        }
        .store(in: &cancellables)

    }

    /// Starts runtime and observer services once AppKit reports that app launch finished.
    func applicationDidFinishLaunching(_ notification: Notification) {
        startRuntimeIfPreferredEngineRequiresIt()
        focusModel.start()
        inputMonitor.start()
        appUpdateManager.start()
        suggestionCoordinator.start()
        welcomeCoordinator.presentIfNeeded()
    }

    /// Stops long-lived services before process exit so observers and runtime resources detach cleanly.
    func applicationWillTerminate(_ notification: Notification) {
        activationIndicatorController.hide(reason: "Activation indicator hidden because Tabby is terminating.")
        focusDebugOverlayController?.hide()
        suggestionCoordinator.stop()
        inputMonitor.stop()
        focusModel.stop()
        runtimeModel.stop()
    }

    /// Mirrors supported-focus state into the selected activation indicator mode.
    /// Different modes intentionally use different geometry contracts: caret-anchor mode hugs the
    /// insertion point, while the icon mode sits outside the field edge.
    private func updateActivationIndicator(for snapshot: FocusSnapshot) {
        guard case .supported = snapshot.capability,
              let context = snapshot.context
        else {
            activationIndicatorController.hide(reason: "Activation indicator hidden.")
            return
        }

        activationIndicatorController.show(
            mode: suggestionSettings.selectedIndicatorMode,
            caretRect: context.caretRect,
            inputFrameRect: context.inputFrameRect
        )
    }

    /// Warm the local runtime only when the user is actually on the open-source engine path.
    /// This avoids noisy startup failures and wasted work for Apple Intelligence users.
    private func startRuntimeIfPreferredEngineRequiresIt() {
        guard suggestionSettings.selectedEngine == .llamaOpenSource else {
            return
        }

        runtimeModel.startIfNeeded()
    }

    /// Model availability can change after downloads or manual file drops. Re-scan first, then
    /// warm the runtime only if the current engine choice needs it.
    private func handleModelDirectoryChange() {
        runtimeModel.refreshAvailableModels()
        startRuntimeIfPreferredEngineRequiresIt()
    }

    /// Composes app state into one render payload for the top-right developer HUD.
    ///
    /// `FocusDebugOverlayController` should stay a dumb renderer. It receives strings and stage
    /// states here instead of reaching back into settings, runtime, or coordinator objects.
    private func updateDeveloperDiagnosticsOverlay() {
        let selectedModel = runtimeModel.availableModels
            .first(where: { $0.filename == runtimeModel.selectedModelFilename })
        let focusContext = focusModel.snapshot.context

        let fields = [
            DeveloperDiagnosticsField(label: "Engine", value: suggestionSettings.selectedEngine.displayLabel),
            DeveloperDiagnosticsField(label: "Model", value: selectedModel?.displayName ?? runtimeModel.selectedModelFilename ?? "n/a"),
            DeveloperDiagnosticsField(label: "Words", value: suggestionSettings.selectedWordCountPreset.displayLabel),
            DeveloperDiagnosticsField(label: "Indicator", value: suggestionSettings.selectedIndicatorMode.displayLabel),
            DeveloperDiagnosticsField(label: "Runtime", value: runtimeModel.state.summary),
            DeveloperDiagnosticsField(label: "Suggest", value: suggestionCoordinator.state.shortLabel),
            DeveloperDiagnosticsField(label: "OCR", value: visualContextLabel(for: suggestionCoordinator.visualContextStatus)),
            DeveloperDiagnosticsField(label: "Focus", value: focusModel.snapshot.applicationName),
            DeveloperDiagnosticsField(label: "Caret", value: focusContext?.caretQuality.label ?? "n/a"),
            DeveloperDiagnosticsField(
                label: "Gen",
                value: suggestionCoordinator.latestGenerationNumber.map(String.init) ?? "n/a"
            ),
        ]

        let overlaySnapshot = DeveloperDiagnosticsOverlaySnapshot(
            overlaysEnabled: developerDiagnostics.overlaysEnabled,
            loggingEnabled: developerDiagnostics.loggingEnabled,
            fields: fields,
            contextItem: developerDiagnostics.contextPipelineItem,
            completionItems: developerDiagnostics.completionPipelineItems,
            recentEvents: developerDiagnostics.recentEvents,
            latestAXObserverEvent: focusModel.latestObserverEvent
        )

        focusDebugOverlayController?.render(
            focusSnapshot: focusModel.snapshot,
            diagnostics: overlaySnapshot
        )
    }

    private func visualContextLabel(for status: VisualContextStatus) -> String {
        switch status {
        case .idle:
            return "Idle"
        case .capturing:
            return "Capturing"
        case .extractingText:
            return "Reading"
        case .summarizingText:
            return "Summarizing"
        case .ready:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Failed"
        }
    }
}
