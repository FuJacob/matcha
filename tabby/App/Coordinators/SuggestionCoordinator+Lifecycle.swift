import Foundation

/// File overview:
/// Lifecycle entry points and user preference changes for `SuggestionCoordinator`.
/// These methods are the closest thing this subsystem has to "public commands" from the app and UI.
extension SuggestionCoordinator {
    // MARK: - Lifecycle

    /// Reconciles coordinator state with the current permission and focus environment.
    func start() {
        reconcileWithCurrentEnvironment()
    }

    /// Cancels any pending work and detaches long-lived callbacks during shutdown.
    func stop() {
        cancelPredictionWork()
        visualContextCoordinator.cancel(resetState: true)
        hideOverlay(reason: "Overlay hidden because Tabby stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
        visualContextCoordinator.onStateChange = nil
        visualContextCoordinator.onInjectedContextReady = nil
    }

    /// Clears any active suggestion work before the runtime swaps to a different model.
    /// This prevents stale completions from the previous model from surviving the switch.
    func prepareForRuntimeModelSwitch() {
        cancelPredictionWork()
        interactionState.resetAll()
        visualContextCoordinator.cancel(resetState: true)
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because the runtime model is switching.")
        state = .idle
        latestStageMessage = "Idle: runtime model switching reset active suggestion state."
    }

    // MARK: - User Preferences

    /// Updates the length target used in prompt instructions and persists the user preference.
    func selectWordCountPreset(_ preset: SuggestionWordCountPreset) {
        guard selectedWordCountPreset != preset else {
            return
        }

        selectedWordCountPreset = preset
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)

        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because suggestion length settings changed.")
        state = .idle
        latestStageMessage = "Updated suggestion length to \(preset.displayLabel)."

        if permissionManager.inputMonitoringGranted,
           case .supported = focusModel.snapshot.capability
        {
            schedulePrediction()
        }
    }

    /// Switches prompt strategy between guided and strict prefix-only generation.
    func selectPromptMode(_ mode: SuggestionPromptMode) {
        guard selectedPromptMode != mode else {
            return
        }

        selectedPromptMode = mode
        userDefaults.set(mode.rawValue, forKey: Self.selectedPromptModeDefaultsKey)

        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because prompt mode changed.")
        state = .idle
        latestStageMessage = "Updated prompt mode to \(mode.displayLabel)."

        if mode.usesVisualContext {
            if case .supported = focusModel.snapshot.capability,
               let focusedContext = focusModel.snapshot.context
            {
                visualContextCoordinator.startSessionIfNeeded(for: focusedContext)
            }
        } else {
            visualContextCoordinator.cancel(resetState: true)
        }

        if permissionManager.inputMonitoringGranted,
           case .supported = focusModel.snapshot.capability
        {
            schedulePrediction()
        }
    }
}
