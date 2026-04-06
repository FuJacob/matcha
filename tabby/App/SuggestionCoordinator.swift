import Combine
import CoreGraphics
import Foundation

/// File overview:
/// Coordinates the entire inline-completion pipeline. It listens to focus and input changes,
/// schedules debounced generation, validates freshness, drives the ghost overlay, and accepts
/// suggestions with `Tab`.
///
/// Owns debounce, generation, stale-result rejection, and the ghost-text overlay lifecycle.
/// The important architectural choice is that overlay visibility is derived from the same
/// canonical ready suggestion state that powers `Tab` acceptance.
@MainActor
final class SuggestionCoordinator: ObservableObject {
    @Published private(set) var state: SuggestionDebugState = .idle
    @Published private(set) var overlayState: OverlayState = .hidden(reason: "Overlay idle.")
    @Published private(set) var latestSuggestionPreview: String?
    @Published private(set) var latestFullSuggestionPreview: String?
    @Published private(set) var latestRemainingSuggestionPreview: String?
    @Published private(set) var latestAcceptedCharacterCount: Int?
    @Published private(set) var latestRemainingCharacterCount: Int?
    @Published private(set) var latestAcceptanceAction: String?
    @Published private(set) var latestLatencyMilliseconds: Int?
    @Published private(set) var latestStageMessage = "Idle"
    @Published private(set) var latestOverlayMessage = "Overlay idle."
    @Published private(set) var latestRequestPreview: String?
    @Published private(set) var latestPromptPreview: String?
    @Published private(set) var latestRawModelOutput: String?
    @Published private(set) var latestGenerationNumber: UInt64?
    @Published private(set) var visualContextStatus: VisualContextStatus = .idle
    @Published private(set) var latestInjectedContextSummary: String?
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset = .threeToSeven
    @Published private(set) var selectedPromptMode: SuggestionPromptMode = .guided

    private let permissionManager: PermissionManager
    private let focusModel: FocusTrackingModel
    private let inputMonitor: InputMonitor
    private let overlayController: OverlayController
    private let suggestionInserter: SuggestionInserter
    private let suggestionEngine: LlamaSuggestionEngine
    private let screenshotContextGenerator: ScreenshotContextGenerator
    private let contextBuffer: ContextBuffer
    private let configuration: SuggestionConfiguration
    private let userDefaults: UserDefaults

    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let selectedPromptModeDefaultsKey = "selectedSuggestionPromptMode"

    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var visualContextTask: Task<Void, Never>?
    private var latestWorkID: UInt64 = 0
    private var lastLoggedMessage: String?
    private var activeSession: ActiveSuggestionSession?
    private var activeAugmentationSession: FocusedInputAugmentationSession?
    /// After Tab inserts a chunk, AX may not reflect the new text for one or more poll cycles.
    /// This sentinel records the consumed count we just committed so reconcile() does not
    /// misinterpret the stale AX state as an undo and drop the session.
    private var pendingInsertionConsumedCount: Int?
    private let consoleStages: Set<String> = [
        "generating",
        "ready",
        "empty-result",
        "failed",
        "tab-accepted-chunk",
        "tab-accepted-final-chunk",
        "typed-match-advanced",
        "typed-match-exhausted",
        "session-reconciled",
        "session-exhausted"
    ]

    init(
        permissionManager: PermissionManager,
        focusModel: FocusTrackingModel,
        inputMonitor: InputMonitor,
        overlayController: OverlayController,
        suggestionInserter: SuggestionInserter,
        suggestionEngine: LlamaSuggestionEngine,
        screenshotContextGenerator: ScreenshotContextGenerator,
        contextBuffer: ContextBuffer,
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        let storedWordCountPreset = userDefaults
            .string(forKey: Self.selectedWordCountPresetDefaultsKey)
            .flatMap(SuggestionWordCountPreset.init(rawValue:))
        let resolvedWordCountPreset = storedWordCountPreset ?? configuration.defaultWordCountPreset
        let storedPromptMode = userDefaults
            .string(forKey: Self.selectedPromptModeDefaultsKey)
            .flatMap(SuggestionPromptMode.init(rawValue:))
        let resolvedPromptMode = storedPromptMode ?? configuration.defaultPromptMode

        self.permissionManager = permissionManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.overlayController = overlayController
        self.suggestionInserter = suggestionInserter
        self.suggestionEngine = suggestionEngine
        self.screenshotContextGenerator = screenshotContextGenerator
        self.contextBuffer = contextBuffer
        self.configuration = configuration
        self.userDefaults = userDefaults
        selectedWordCountPreset = resolvedWordCountPreset
        selectedPromptMode = resolvedPromptMode

        if storedWordCountPreset == nil {
            userDefaults.set(resolvedWordCountPreset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
        }

        if storedPromptMode == nil {
            userDefaults.set(resolvedPromptMode.rawValue, forKey: Self.selectedPromptModeDefaultsKey)
        }

        overlayState = overlayController.state
        latestOverlayMessage = overlayController.state.detail

        focusModel.$snapshot
            .sink { [weak self] snapshot in
                self?.handleFocusSnapshotChange(snapshot)
            }
            .store(in: &cancellables)

        permissionManager.$inputMonitoringGranted
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        permissionManager.$screenRecordingGranted
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        inputMonitor.onEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? false
        }

        inputMonitor.onSuppressedSyntheticInput = { [weak self] in
            self?.handleSuppressedSyntheticInput()
        }

        overlayController.onStateChange = { [weak self] state in
            self?.overlayState = state
        }
    }

    /// Reconciles coordinator state with the current permission and focus environment.
    func start() {
        reconcileWithCurrentEnvironment()
    }

    /// Cancels any pending work and detaches long-lived callbacks during shutdown.
    func stop() {
        cancelPredictionWork()
        cancelVisualContextWork(resetState: true)
        hideOverlay(reason: "Overlay hidden because Tabby stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
    }

    /// Clears any active suggestion work before the runtime swaps to a different model.
    /// This prevents stale completions from the previous model from surviving the switch.
    func prepareForRuntimeModelSwitch() {
        cancelPredictionWork()
        contextBuffer.clear()
        cancelVisualContextWork(resetState: true)
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because the runtime model is switching.")
        state = .idle
        latestStageMessage = "Idle: runtime model switching reset active suggestion state."
    }

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
                startVisualContextSessionIfNeeded(for: focusedContext)
            }
        } else {
            cancelVisualContextWork(resetState: true)
        }

        if permissionManager.inputMonitoringGranted,
           case .supported = focusModel.snapshot.capability
        {
            schedulePrediction()
        }
    }

    private func handlePermissionChange() {
        if !permissionManager.screenRecordingGranted {
            cancelVisualContextWork(resetState: true)
        }

        reconcileWithCurrentEnvironment()

        if permissionManager.inputMonitoringGranted,
           case .supported = focusModel.snapshot.capability
        {
            handleSupportedSnapshot(focusModel.snapshot)
        }
    }

    private func handleFocusSnapshotChange(_ snapshot: FocusSnapshot) {
        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Tabby can react to typing.")
            return
        }

        switch snapshot.capability {
        case .supported:
            handleSupportedSnapshot(snapshot)

        case let .blocked(reason), let .unsupported(reason):
            disablePredictions(reason: reason)
        }
    }

    private func handleSupportedSnapshot(_ snapshot: FocusSnapshot) {
        guard let focusedContext = snapshot.context else {
            disablePredictions(reason: "No focused text input.")
            return
        }

        if selectedPromptMode.usesVisualContext {
            startVisualContextSessionIfNeeded(for: focusedContext)
        } else if visualContextStatus != .idle {
            cancelVisualContextWork(resetState: true)
        }

        if case .disabled = state {
            state = .idle
        }

        if activeSession != nil {
            reconcileActiveSession(with: snapshot)
            return
        }

        if let currentContext = contextBuffer.currentContext,
           currentContext.elementIdentifier != focusedContext.elementIdentifier {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because the focused field changed.")
            state = .idle
        }

        if overlayState.isVisible {
            hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
        }
    }

    private func handleInputEvent(_ event: CapturedInputEvent) -> Bool {
        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Tabby can react to typing.")
            return false
        }

        if event.kind == .tab {
            return acceptCurrentSuggestion()
        }

        if let activeSession {
            return handleInputEvent(event, with: activeSession)
        }

        if event.shouldClearSuggestion {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: overlayHideReason(for: event))
            if !event.shouldSchedulePrediction {
                state = .idle
            }
        }

        if event.shouldSchedulePrediction {
            schedulePrediction()
        }

        return false
    }

    private func handleSuppressedSyntheticInput() {
        logStage(
            "suppressed-synthetic-input",
            workID: latestWorkID,
            generation: latestGenerationNumber,
            message: "Ignored Tabby's own synthetic key event."
        )
    }

    /// While a suggestion tail is active, normal typing is interpreted relative to that tail first.
    /// This is the same idea as reconciling optimistic UI with the eventual server state:
    /// keep the existing session only when the user's new input is still consistent with it.
    private func handleInputEvent(_ event: CapturedInputEvent, with session: ActiveSuggestionSession) -> Bool {
        switch event.kind {
        case .textMutation:
            if advanceActiveSessionIfTypedCharactersMatch(event.characters, session: session) {
                return false
            }

            invalidateActiveSuggestion(
                reason: overlayHideReason(for: event),
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePrediction()
            }
            return false

        case .shortcutMutation:
            invalidateActiveSuggestion(
                reason: "Overlay hidden because a shortcut changed the text and invalidated the current suggestion.",
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePrediction()
            }
            return false

        case .navigation, .dismissal:
            invalidateActiveSuggestion(
                reason: overlayHideReason(for: event),
                clearDiagnostics: false
            )
            state = .idle
            return false

        case .other, .tab:
            return false
        }
    }

    private func schedulePrediction() {
        guard case .supported = focusModel.snapshot.capability else {
            disablePredictions(reason: focusModel.snapshot.capability.summary)
            return
        }

        // Task cancellation in Swift is cooperative, so we also use an explicit work id.
        // That gives us strict "latest request wins" semantics even if an old task wakes up late.
        cancelPredictionWork()
        let workID = nextWorkID()

        state = .debouncing
        logStage("debouncing", workID: workID, message: "Waiting \(configuration.debounceMilliseconds)ms before generating.")

        debounceTask = Task { [weak self] in
            guard let self else {
                return
            }

            let delayNanoseconds = UInt64(configuration.debounceMilliseconds) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            guard workID == self.latestWorkID else {
                return
            }

            await self.generateFromCurrentFocus(workID: workID)
        }
    }

    /// Refreshes focus after debounce, materializes a stable context, and starts generation.
    private func generateFromCurrentFocus(workID: UInt64) async {
        guard workID == latestWorkID else {
            return
        }

        // We intentionally re-read the latest focus snapshot here instead of trusting the earlier
        // key event, because the user may have switched apps or fields during the debounce window.
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Tabby can react to typing.")
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        guard shouldGenerateSuggestion(for: rawContext.precedingText) else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because suggestions wait for a completed word boundary (space).")
            state = .idle
            return
        }

        let context = contextBuffer.materialize(from: rawContext)
        let injectedContextSummary = selectedPromptMode.usesVisualContext ? injectedContextSummary(for: context) : nil
        let prompt = buildPrompt(from: context, injectedContextSummary: injectedContextSummary)
        let requestPreview = buildRequestPreview(hasInjectedContext: injectedContextSummary != nil)
        latestGenerationNumber = context.generation
        latestRequestPreview = requestPreview
        latestPromptPreview = prompt
        latestRawModelOutput = nil
        let request = SuggestionRequest(
            context: context,
            prompt: prompt,
            injectedContextSummary: injectedContextSummary,
            generation: context.generation,
            maxPredictionTokens: activeMaxPredictionTokens,
            temperature: configuration.temperature,
            topK: configuration.topK,
            topP: configuration.topP,
            minP: configuration.minP,
            repetitionPenalty: configuration.repetitionPenalty,
            maxSuffixCharacters: configuration.maxSuffixCharacters,
            customAIInstructions: activeCompletionInstruction
        )

        state = .generating
        logStage(
            "generating",
            workID: workID,
            generation: context.generation,
            message: "Requesting a completion for \(context.elementIdentifier).",
            request: requestPreview,
            prompt: prompt
        )

        generationTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await suggestionEngine.generateSuggestion(for: request)
                guard !Task.isCancelled else {
                    return
                }
                guard workID == self.latestWorkID else {
                    return
                }

                await apply(result: result, workID: workID)
            } catch SuggestionClientError.cancelled {
                return
            } catch {
                guard workID == self.latestWorkID else {
                    return
                }

                await applyFailure(error.localizedDescription, workID: workID)
            }
        }
    }

    /// Promotes a generated result to `ready` only when it is still fresh for the current field.
    private func apply(result: SuggestionResult, workID: UInt64) async {
        guard workID == latestWorkID else {
            return
        }

        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Tabby can react to typing.")
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        let liveContext = contextBuffer.materialize(from: rawContext)
        // Generation numbers are our stale-result guard. If the text changed while the model was
        // thinking, we drop the answer instead of showing a suggestion for old content.
        guard liveContext.generation == result.generation else {
            latestRawModelOutput = makeDebugPreview(result.rawText)
            logStage(
                "stale-drop",
                workID: workID,
                generation: result.generation,
                message: "Dropped stale result because live generation is \(liveContext.generation).",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            hideOverlay(reason: "Overlay hidden because a stale result was dropped.")
            return
        }

        latestRawModelOutput = makeDebugPreview(result.rawText)

        guard !result.text.isEmpty else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the model returned an empty continuation.")
            state = .idle
            logStage(
                "empty-result",
                workID: workID,
                generation: result.generation,
                message: "Model returned an empty or whitespace-only continuation after normalization.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        guard liveContext.selection.length == 0 else {
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because text is selected.")
            state = .idle
            logStage(
                "selected-text",
                workID: workID,
                generation: result.generation,
                message: "Ignored the suggestion because the current field has selected text.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        let session = ActiveSuggestionSession(
            baseContext: liveContext,
            fullText: result.text,
            latency: result.latency,
            rawText: result.rawText,
            finishReason: result.finishReason
        )

        latestLatencyMilliseconds = Int(result.latency * 1000)
        latestGenerationNumber = liveContext.generation
        activeSession = session
        applySessionDiagnostics(session, acceptanceAction: "Generated new suggestion.")
        state = .ready(text: session.remainingText, latency: session.latency)
        presentOverlay(text: session.remainingText, at: liveContext.caretRect)
        logStage(
            "ready",
            workID: workID,
            generation: result.generation,
            message: "Accepted a non-empty normalized suggestion.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )
    }

    /// Converts a runtime or engine failure into visible coordinator state and clears stale UI.
    private func applyFailure(_ message: String, workID: UInt64) async {
        guard workID == latestWorkID else {
            return
        }

        clearSuggestion()
        hideOverlay(reason: "Overlay hidden because generation failed.")
        state = .failed(message)
        logStage("failed", workID: workID, generation: latestGenerationNumber, message: message)
    }

    /// Recomputes whether prediction should be enabled based on current permissions and focus support.
    private func reconcileWithCurrentEnvironment() {
        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Tabby can react to typing.")
            return
        }

        switch focusModel.snapshot.capability {
        case .supported:
            if case .disabled = state {
                state = .idle
            }

        case let .blocked(reason), let .unsupported(reason):
            disablePredictions(reason: reason)
        }
    }

    /// Reconciles the active suggestion session with the latest live AX context.
    /// This is the heart of partial acceptance: a text change is not automatically "stale" anymore.
    /// It may instead mean "the user consumed the next expected part of the suggestion."
    private func reconcileActiveSession(with snapshot: FocusSnapshot) {
        guard let session = activeSession else {
            if overlayState.isVisible {
                hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
            }
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            invalidateActiveSuggestion(reason: snapshot.capability.summary)
            return
        }

        let liveContext = contextBuffer.materialize(from: rawContext)

        switch reconcile(session: session, with: liveContext) {
        case let .valid(reconciledSession, advancement):
            activeSession = reconciledSession
            latestGenerationNumber = liveContext.generation
            applySessionDiagnostics(reconciledSession, acceptanceAction: advancement?.actionSummary ?? latestAcceptanceAction)

            if reconciledSession.isExhausted {
                completeActiveSuggestion(
                    reason: "Overlay hidden because the active suggestion was fully consumed.",
                    scheduleNextPrediction: true,
                    stage: advancement?.exhaustionStage ?? "session-exhausted",
                    message: advancement?.exhaustionMessage ?? "The active suggestion was fully consumed.",
                    acceptanceAction: advancement?.actionSummary ?? "Suggestion tail was fully consumed."
                )
                return
            }

            state = .ready(text: reconciledSession.remainingText, latency: reconciledSession.latency)
            presentOverlay(text: reconciledSession.remainingText, at: liveContext.caretRect)
            if let advancement {
                logStage(
                    advancement.stage,
                    workID: latestWorkID,
                    generation: liveContext.generation,
                    message: advancement.message,
                    normalizedOutput: reconciledSession.remainingText
                )
            }

        case let .invalid(reason):
            invalidateActiveSuggestion(reason: reason)
        }
    }

    /// Fully disables prediction, clears cached context, and updates UI messaging with the cause.
    private func disablePredictions(reason: String) {
        cancelPredictionWork()
        cancelVisualContextWork(resetState: true)
        contextBuffer.clear()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .disabled(reason)
        latestStageMessage = "Disabled: \(reason)"
    }

    /// Clears the active suggestion and optionally preserves or drops diagnostic breadcrumbs.
    private func clearSuggestion(clearDiagnostics: Bool = false) {
        latestSuggestionPreview = nil
        latestFullSuggestionPreview = nil
        latestRemainingSuggestionPreview = nil
        latestAcceptedCharacterCount = nil
        latestRemainingCharacterCount = nil
        latestAcceptanceAction = nil
        latestLatencyMilliseconds = nil
        activeSession = nil
        pendingInsertionConsumedCount = nil

        if clearDiagnostics {
            latestRequestPreview = nil
            latestPromptPreview = nil
            latestRawModelOutput = nil
            latestGenerationNumber = nil
        }
    }

    /// Cancels debounce/generation tasks and advances the work id so late completions are ignored.
    private func cancelPredictionWork() {
        debounceTask?.cancel()
        generationTask?.cancel()
        debounceTask = nil
        generationTask = nil
        latestWorkID &+= 1
    }

    /// Starts one screenshot-derived augmentation session per focused field.
    /// We intentionally scope this to field identity rather than text generation number because
    /// the screenshot context should survive normal typing inside the same input.
    private func startVisualContextSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {
        if let activeAugmentationSession,
           activeAugmentationSession.elementIdentifier == snapshotContext.elementIdentifier
        {
            if case .unavailable(let reason) = activeAugmentationSession.status,
               reason.localizedCaseInsensitiveContains("Screen Recording"),
               permissionManager.screenRecordingGranted
            {
                cancelVisualContextWork(resetState: true)
            } else {
                return
            }
        }

        cancelVisualContextWork(resetState: false)

        let initialStatus: VisualContextStatus = permissionManager.screenRecordingGranted
            ? .capturing
            : .unavailable("Screen Recording permission is required for screenshot-derived prompt context.")
        let session = FocusedInputAugmentationSession(
            sessionID: UUID(),
            elementIdentifier: snapshotContext.elementIdentifier,
            contentSignatureAtStart: snapshotContext.contentSignature,
            status: initialStatus,
            injectedContext: nil
        )

        activeAugmentationSession = session
        visualContextStatus = initialStatus
        latestInjectedContextSummary = nil

        guard permissionManager.screenRecordingGranted else {
            return
        }

        visualContextTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let injectedContext = try await screenshotContextGenerator.generateContext(
                    for: snapshotContext,
                    onStatusChange: { [weak self] status in
                        await self?.setVisualContextStatus(status, for: session.sessionID)
                    }
                )
                guard !Task.isCancelled else {
                    return
                }

                applyInjectedVisualContext(
                    injectedContext,
                    for: session.sessionID,
                    elementIdentifier: snapshotContext.elementIdentifier
                )
            } catch is CancellationError {
                return
            } catch let error as ScreenshotContextGenerationError {
                setVisualContextStatus(
                    errorStatus(for: error),
                    for: session.sessionID
                )
            } catch {
                setVisualContextStatus(
                    .failed(error.localizedDescription),
                    for: session.sessionID
                )
            }
        }
    }

    /// Updates only the current augmentation session so stale async screenshot work cannot mutate
    /// the next field after focus changes.
    private func setVisualContextStatus(_ status: VisualContextStatus, for sessionID: UUID) {
        guard activeAugmentationSession?.sessionID == sessionID else {
            return
        }

        activeAugmentationSession?.status = status
        visualContextStatus = status
    }

    /// Commits the generated screenshot summary and optionally refreshes suggestions for the
    /// still-focused field so subsequent predictions pick up the new injected context.
    private func applyInjectedVisualContext(
        _ injectedContext: InjectedVisualContext,
        for sessionID: UUID,
        elementIdentifier: String
    ) {
        guard activeAugmentationSession?.sessionID == sessionID,
              activeAugmentationSession?.elementIdentifier == elementIdentifier
        else {
            return
        }

        activeAugmentationSession?.status = .ready
        activeAugmentationSession?.injectedContext = injectedContext
        visualContextStatus = .ready
        latestInjectedContextSummary = injectedContext.summary

        schedulePredictionForCurrentFocusIfPossible(matching: elementIdentifier)
    }

    /// Once screenshot context becomes ready, regenerate only if the user is still in the same
    /// field and there is enough typed text for a real inline completion request.
    private func schedulePredictionForCurrentFocusIfPossible(matching elementIdentifier: String) {
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard case .supported = snapshot.capability,
              let context = snapshot.context,
              context.elementIdentifier == elementIdentifier,
              shouldGenerateSuggestion(for: context.precedingText)
        else {
            return
        }

        schedulePrediction()
    }

    /// Clears screenshot-derived context state and cancels any in-flight capture/OCR/summary work.
    private func cancelVisualContextWork(resetState: Bool) {
        visualContextTask?.cancel()
        visualContextTask = nil
        activeAugmentationSession = nil
        latestInjectedContextSummary = nil

        if resetState {
            visualContextStatus = .idle
        }
    }

    private func injectedContextSummary(for context: FocusedInputContext) -> String? {
        guard let activeAugmentationSession,
              activeAugmentationSession.elementIdentifier == context.elementIdentifier,
              activeAugmentationSession.status == .ready
        else {
            return nil
        }

        return activeAugmentationSession.injectedContext?.summary
    }

    private func errorStatus(for error: ScreenshotContextGenerationError) -> VisualContextStatus {
        switch error {
        case let .unavailable(message):
            return .unavailable(message)
        case let .failed(message):
            return .failed(message)
        }
    }

    /// Builds the prompt contract that the local model sees for the current focused field.
    private func buildPrompt(
        from context: FocusedInputContext,
        injectedContextSummary: String?
    ) -> String {
        let prefix = truncatedPromptPrefix(from: context.precedingText)

        if selectedPromptMode == .prefixOnly {
            // Prefix-only mode intentionally sends no system instructions or extra context.
            return prefix
        }

        var sections = [
            "You are an inline autocomplete engine for one text field.",
            "",
            "Rules (highest priority):",
            "Return exactly one continuation fragment.",
            selectedWordCountPreset.promptInstruction,
            "Continue only from Prefix.",
            "Do not repeat Prefix text.",
            "ScreenContextHints are background hints only; never restate or continue them.",
            "No numbering, no bullets, no labels, no quotes, no markdown, no newline.",
            "Output plain text only."
        ]

        if let screenContextHints = normalizedScreenContextHints(from: injectedContextSummary) {
            sections.append("ScreenContextHints: \(screenContextHints)")
        }

        sections.append("Prefix: \(prefix)")
        sections.append("Continuation:")
        return sections.joined(separator: "\n")
    }

    /// Screen context should be metadata, not prose continuation, so we normalize it into one line.
    private func normalizedScreenContextHints(from summary: String?) -> String? {
        guard let summary else {
            return nil
        }

        var normalized = summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\r", with: "")
            .replacingOccurrences(of: "\\n+", with: ", ", options: .regularExpression)
            .replacingOccurrences(
                of: "^\\s*ScreenContextHints?\\s*:\\s*",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))

        if normalized.count > 160 {
            normalized = String(normalized.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalized.isEmpty ? nil : normalized
    }

    /// Require completed word boundaries so prompts do not include half-typed trailing tokens.
    private func shouldGenerateSuggestion(for precedingText: String) -> Bool {
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard let trailingScalar = precedingText.unicodeScalars.last else {
            return false
        }

        return CharacterSet.whitespaces.contains(trailingScalar)
    }

    /// Keep only the latest short word tail to prevent long stale context from steering output.
    private func truncatedPromptPrefix(from precedingText: String) -> String {
        let characterWindow = String(precedingText.suffix(configuration.maxPrefixCharacters))
        let trailingWords = characterWindow
            .split(whereSeparator: { $0.isWhitespace })
            .suffix(configuration.maxPrefixWords)
            .map(String.init)
            .joined(separator: " ")

        return trailingWords.isEmpty ? characterWindow : trailingWords
    }
    
    
    private func nextWorkID() -> UInt64 {
        latestWorkID &+= 1
        return latestWorkID
    }

    /// Produces a compact operator-facing summary of the current generation configuration.
    private func buildRequestPreview(hasInjectedContext: Bool) -> String {
        let screenshotContextSummary: String
        if selectedPromptMode.usesVisualContext {
            screenshotContextSummary = hasInjectedContext ? "ready" : visualContextStatus.shortLabel.lowercased()
        } else {
            screenshotContextSummary = "disabled"
        }

        return """
        Backend: llama.swift
        transport: in-process
        suggestion_words: \(selectedWordCountPreset.displayLabel)
        prompt_mode: \(selectedPromptMode.displayLabel)
        n_predict: \(activeMaxPredictionTokens)
        temperature: \(configuration.temperature)
        top_k: \(configuration.topK)
        top_p: \(configuration.topP)
        min_p: \(configuration.minP)
        repetition_penalty: \(configuration.repetitionPenalty)
        prompt_style: \(selectedPromptMode == .prefixOnly ? "prefix-only" : "guided")
        screenshot_context: \(screenshotContextSummary)
        stop: first line only
        """
    }

    private var activeCompletionInstruction: String {
        [configuration.customAIInstructions, selectedWordCountPreset.promptInstruction]
            .joined(separator: " ")
    }

    private var activeMaxPredictionTokens: Int {
        max(configuration.maxPredictionTokens, selectedWordCountPreset.suggestedPredictionTokenBudget)
    }

    /// Accepts the current suggestion only if the field, generation, and visible overlay still match.
    private func acceptCurrentSuggestion() -> Bool {
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            return passTabThrough(reason: "Input Monitoring permission is required before Tabby can accept Tab.")
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return passTabThrough(reason: snapshot.capability.summary)
        }

        guard case .ready = state, let currentSession = activeSession else {
            return passTabThrough(reason: "Tab passed through because no valid suggestion was ready.")
        }

        guard rawContext.selection.length == 0 else {
            return passTabThrough(reason: "Tab passed through because text is currently selected.")
        }

        guard overlayAllowsAcceptance(of: currentSession.remainingText) else {
            return passTabThrough(reason: "Tab passed through because no visible ghost text matched the ready suggestion.")
        }

        let sessionForAcceptance: ActiveSuggestionSession
        let liveContext = contextBuffer.materialize(from: rawContext)
        if overlayState.isVisible {
            // A visible overlay means AX has already caught up to the current caret/text state,
            // so we can insist that live editor state and session state agree before accepting.
            switch reconcile(session: currentSession, with: liveContext) {
            case .invalid(let reason):
                return passTabThrough(reason: reason)

            case .valid(let reconciledSession, _):
                sessionForAcceptance = reconciledSession
            }
        } else {
            // We intentionally allow acceptance while the overlay is temporarily hidden.
            // That hidden state usually means "waiting for host app caret sync" after a prior
            // partial acceptance, not "there is no active suggestion anymore."
            guard liveContext.elementIdentifier == currentSession.baseContext.elementIdentifier else {
                return passTabThrough(reason: "Tab passed through because the focused field changed.")
            }
            sessionForAcceptance = currentSession
        }

        guard !sessionForAcceptance.isExhausted else {
            return passTabThrough(reason: "Tab passed through because no remaining suggestion text was available.")
        }

        let acceptedChunk = nextAcceptanceChunk(from: sessionForAcceptance.remainingText)
        guard !acceptedChunk.isEmpty else {
            return passTabThrough(reason: "Tab passed through because no remaining suggestion chunk was available.")
        }

        guard suggestionInserter.insert(acceptedChunk) else {
            let message = suggestionInserter.lastErrorMessage ?? "Suggestion insertion failed."
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because suggestion insertion failed.")
            state = .idle
            logStage(
                "insert-failed",
                workID: latestWorkID,
                generation: liveContext.generation,
                message: message,
                normalizedOutput: acceptedChunk
            )
            return false
        }

        cancelPredictionWork()

        let advancedSession = sessionForAcceptance.advancing(by: acceptedChunk.count)
        latestGenerationNumber = liveContext.generation
        // Arm the sentinel so reconcile() tolerates stale AX state for the next poll cycle.
        pendingInsertionConsumedCount = advancedSession.consumedCharacterCount

        if advancedSession.isExhausted {
            pendingInsertionConsumedCount = nil
            clearSuggestion(clearDiagnostics: false)
            hideOverlay(reason: "Overlay hidden because Tab accepted the final suggestion chunk.")
            latestAcceptanceAction = "Accepted final chunk with Tab."
            state = .idle
            logStage(
                "tab-accepted-final-chunk",
                workID: latestWorkID,
                generation: liveContext.generation,
                message: "Inserted the final suggestion chunk and queued a refresh.",
                normalizedOutput: acceptedChunk
            )
            schedulePrediction()
            return true
        }

        activeSession = advancedSession
        applySessionDiagnostics(advancedSession, acceptanceAction: "Accepted next chunk with Tab.")
        state = .ready(text: advancedSession.remainingText, latency: advancedSession.latency)
        // Optimistic overlay: show the remaining suggestion text immediately at the last known
        // caret position instead of hiding and waiting for AX to report the new caret. The overlay
        // position will be slightly stale (by roughly the inserted chunk width) for one poll cycle,
        // then snap to the correct position when AX catches up. This eliminates the flash where
        // ghost text disappears and reappears between Tab presses.
        presentOverlay(text: advancedSession.remainingText, at: liveContext.caretRect)
        logStage(
            "tab-accepted-chunk",
            workID: latestWorkID,
            generation: liveContext.generation,
            message: "Inserted the next suggestion chunk and kept the remaining tail active.",
            normalizedOutput: acceptedChunk
        )
        return true
    }

    /// Returns control of `Tab` to the host app and clears stale suggestion UI.
    private func passTabThrough(reason: String) -> Bool {
        let generation = latestGenerationNumber
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .idle
        logStage(
            "tab-passed-through",
            workID: latestWorkID,
            generation: generation,
            message: reason
        )
        return false
    }

    /// Advances the active session from the user's directly typed characters when they match the
    /// next expected tail exactly. This avoids a wasteful regeneration for text the user already
    /// committed to the field themselves.
    private func advanceActiveSessionIfTypedCharactersMatch(_ typedCharacters: String, session: ActiveSuggestionSession) -> Bool {
        guard typedCharacters.isDirectTextMutation else {
            return false
        }

        guard session.remainingText.hasPrefix(typedCharacters) else {
            return false
        }

        cancelPredictionWork()
        let advancedSession = session.advancing(by: typedCharacters.count)
        activeSession = advancedSession
        applySessionDiagnostics(advancedSession, acceptanceAction: "User typed the next expected characters.")

        if advancedSession.isExhausted {
            completeActiveSuggestion(
                reason: "Overlay hidden because the user typed through the rest of the suggestion.",
                scheduleNextPrediction: true,
                stage: "typed-match-exhausted",
                message: "The user typed the remaining suggestion characters exactly.",
                acceptanceAction: "User typed through the rest of the suggestion."
            )
            return true
        }

        state = .ready(text: advancedSession.remainingText, latency: advancedSession.latency)
        presentOverlay(text: advancedSession.remainingText, at: session.baseContext.caretRect)
        logStage(
            "typed-match-advanced",
            workID: latestWorkID,
            generation: latestGenerationNumber,
            message: "User typing matched the active suggestion tail exactly.",
            normalizedOutput: advancedSession.remainingText
        )
        return true
    }

    private func invalidateActiveSuggestion(
        reason: String,
        clearDiagnostics: Bool = true
    ) {
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: clearDiagnostics)
        hideOverlay(reason: reason)
        state = .idle
    }

    private func completeActiveSuggestion(
        reason: String,
        scheduleNextPrediction: Bool,
        stage: String,
        message: String,
        acceptanceAction: String
    ) {
        let generation = latestGenerationNumber
        clearSuggestion(clearDiagnostics: false)
        latestAcceptanceAction = acceptanceAction
        hideOverlay(reason: reason)
        state = .idle
        logStage(stage, workID: latestWorkID, generation: generation, message: message)

        if scheduleNextPrediction {
            schedulePrediction()
        }
    }

    private func applySessionDiagnostics(_ session: ActiveSuggestionSession, acceptanceAction: String?) {
        latestSuggestionPreview = session.remainingText
        latestFullSuggestionPreview = session.fullText
        latestRemainingSuggestionPreview = session.remainingText
        latestAcceptedCharacterCount = session.acceptedCount
        latestRemainingCharacterCount = session.remainingCount
        if let acceptanceAction {
            latestAcceptanceAction = acceptanceAction
        }
    }

    private func reconcile(session: ActiveSuggestionSession, with liveContext: FocusedInputContext) -> SessionReconciliation {
        guard liveContext.elementIdentifier == session.baseContext.elementIdentifier else {
            return .invalid("Overlay hidden because the focused field changed.")
        }

        guard liveContext.selection.length == 0 else {
            return .invalid("Overlay hidden because text is selected.")
        }

        guard liveContext.trailingText == session.baseContext.trailingText else {
            return .invalid("Overlay hidden because text after the caret changed.")
        }

        guard liveContext.precedingText.hasPrefix(session.baseContext.precedingText) else {
            return .invalid("Overlay hidden because text before the caret no longer matches the suggestion anchor.")
        }

        let consumedSuffix = String(liveContext.precedingText.dropFirst(session.baseContext.precedingText.count))
        guard session.fullText.hasPrefix(consumedSuffix) else {
            // If we just inserted via Tab, AX may still show stale text. Trust the sentinel
            // for one reconciliation cycle instead of invalidating the whole session.
            if let pending = pendingInsertionConsumedCount, pending == session.consumedCharacterCount {
                return .valid(session, advancement: nil)
            }
            return .invalid("Overlay hidden because typed text diverged from the active suggestion.")
        }

        // AX caught up (or never lagged) — clear the sentinel.
        if pendingInsertionConsumedCount != nil, consumedSuffix.count >= session.consumedCharacterCount {
            pendingInsertionConsumedCount = nil
        }

        guard consumedSuffix.count >= session.consumedCharacterCount else {
            // Same AX lag protection: if we just Tab-inserted, the preceding text hasn't updated yet.
            if let pending = pendingInsertionConsumedCount, pending == session.consumedCharacterCount {
                return .valid(session, advancement: nil)
            }
            return .invalid("Overlay hidden because the active suggestion was partially undone.")
        }

        let reconciledSession = session.withConsumedCharacters(consumedSuffix.count)
        guard consumedSuffix.count != session.consumedCharacterCount else {
            return .valid(reconciledSession, advancement: nil)
        }

        let advancedBy = consumedSuffix.count - session.consumedCharacterCount
        let consumedAdvance = String(reconciledSession.acceptedText.suffix(advancedBy))
        let advancement = SessionAdvancement(
            stage: reconciledSession.isExhausted ? "session-exhausted" : "session-reconciled",
            message: reconciledSession.isExhausted
                ? "The live field state caught up with the fully consumed suggestion."
                : "The live field state consumed \(advancedBy) additional suggestion characters.",
            actionSummary: "Suggestion tail advanced from live editor state.",
            exhaustionStage: "session-exhausted",
            exhaustionMessage: "The live field state fully consumed the active suggestion.",
            consumedText: consumedAdvance
        )
        return .valid(reconciledSession, advancement: advancement)
    }

    /// Accepts optional leading whitespace plus the next visible token.
    /// This is intentionally a user-facing chunking rule rather than a model-token rule.
    private func nextAcceptanceChunk(from remainingText: String) -> String {
        guard !remainingText.isEmpty else {
            return ""
        }

        var index = remainingText.startIndex
        while index < remainingText.endIndex, remainingText[index].isWhitespace {
            index = remainingText.index(after: index)
        }

        while index < remainingText.endIndex, !remainingText[index].isWhitespace {
            index = remainingText.index(after: index)
        }

        return String(remainingText[..<index])
    }

    private func overlayHideReason(for event: CapturedInputEvent) -> String {
        switch event.kind {
        case .textMutation, .shortcutMutation:
            return "Overlay hidden because typing invalidated the current suggestion."
        case .navigation:
            return "Overlay hidden because caret navigation invalidated the current suggestion."
        case .dismissal:
            return "Overlay hidden because a dismissal key was pressed."
        case .tab, .other:
            return "Overlay hidden."
        }
    }

    /// The overlay may be hidden briefly while we wait for the host app to publish an updated
    /// caret position after partial acceptance, so hidden does not automatically mean "reject Tab."
    private func overlayAllowsAcceptance(of text: String) -> Bool {
        guard case let .visible(visibleText, _) = overlayState else {
            return true
        }

        return visibleText == text
    }

    /// Shows or repositions ghost text while keeping overlay state derived from ready suggestions.
    private func presentOverlay(text: String, at caretRect: CGRect) {
        guard !text.isEmpty else {
            hideOverlay(reason: "Overlay hidden because the suggestion text was empty.")
            return
        }

        let previousState = overlayState
        guard previousState != .visible(text: text, caretRect: caretRect) else {
            return
        }

        overlayController.showSuggestion(text, at: caretRect)

        switch previousState {
        case let .visible(previousText, previousCaretRect) where previousText == text && previousCaretRect != caretRect:
            let message = "Moved ghost text to the latest caret position."
            latestOverlayMessage = message
            logOverlay("overlay-moved", message: message, text: text, caretRect: caretRect)

        default:
            let message = "Displayed ghost text near the caret."
            latestOverlayMessage = message
            logOverlay("overlay-shown", message: message, text: text, caretRect: caretRect)
        }
    }

    private func hideOverlay(reason: String) {
        let previousState = overlayState
        overlayController.hide(reason: reason)
        latestOverlayMessage = reason

        switch previousState {
        case .visible:
            logOverlay("overlay-hidden", message: reason)

        case let .hidden(previousReason) where previousReason != reason:
            logOverlay("overlay-hidden", message: reason)

        default:
            break
        }
    }

    /// Emits compact console summaries plus full prompt/output blocks for high-signal stages.
    private func logStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64? = nil,
        message: String,
        request: String? = nil,
        prompt: String? = nil,
        rawOutput: String? = nil,
        normalizedOutput: String? = nil
    ) {
        latestStageMessage = message
        guard consoleStages.contains(stage) else {
            return
        }

        var parts = [
            "[Suggestion]",
            "stage=\(stage)",
            "work=\(workID)"
        ]

        if let generation {
            parts.append("generation=\(generation)")
        }

        parts.append("message=\(message)")

        if stage == "generating", let prompt {
            parts.append("prompt=\(makeDebugPreview(prompt))")
        }

        if stage != "generating" {
            let generationOutput = normalizedOutput ?? rawOutput
            if let generationOutput {
                parts.append("output=\(makeDebugPreview(generationOutput))")
            }
        }

        let summaryLine = parts.joined(separator: " ")
        logLine(summaryLine)

        if stage == "generating", let prompt {
            logTextBlock(
                kind: "prompt",
                stage: stage,
                workID: workID,
                generation: generation,
                text: prompt
            )
        }

        if stage != "generating", let generationOutput = normalizedOutput ?? rawOutput {
            logTextBlock(
                kind: "output",
                stage: stage,
                workID: workID,
                generation: generation,
                text: generationOutput
            )
        }
    }

    private func logOverlay(_ stage: String, message: String, text: String? = nil, caretRect: CGRect? = nil) {
        _ = stage
        _ = message
        _ = text
        _ = caretRect
    }

    private func logLine(_ line: String) {
        guard line != lastLoggedMessage else {
            return
        }

        lastLoggedMessage = line
        print(line)
    }

    /// Compact one-line logs are good for scanning, but debugging prompts needs the exact payload.
    /// We print full blocks here so you can compare Tabby's request with a manual curl byte-for-byte.
    private func logTextBlock(
        kind: String,
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        text: String
    ) {
        let generationSummary = generation.map(String.init) ?? "n/a"
        let renderedText = text.isEmpty ? "<empty>" : text
        print(
            """
            [Suggestion \(kind)] stage=\(stage) work=\(workID) generation=\(generationSummary)
            ----- BEGIN \(kind.uppercased()) -----
            \(renderedText)
            ----- END \(kind.uppercased()) -----
            """
        )
    }

    /// Produces an escaped single-line preview suitable for compact logs and menu summaries.
    private func makeDebugPreview(_ text: String) -> String {
        if text.isEmpty {
            return "<empty>"
        }

        let escaped = text.debugDescription
        if escaped.count <= 160 {
            return escaped
        }

        let index = escaped.index(escaped.startIndex, offsetBy: 160)
        return "\(escaped[..<index])..."
    }
}

private enum SessionReconciliation {
    case valid(ActiveSuggestionSession, advancement: SessionAdvancement?)
    case invalid(String)
}

private struct SessionAdvancement {
    let stage: String
    let message: String
    let actionSummary: String
    let exhaustionStage: String
    let exhaustionMessage: String
    let consumedText: String
}

private extension String {
    /// Direct text input is the only mutation we can safely reconcile optimistically from the
    /// key event alone. Control characters such as backspace or return require regeneration.
    var isDirectTextMutation: Bool {
        guard !isEmpty else {
            return false
        }

        return unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
