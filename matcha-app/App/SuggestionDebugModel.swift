import Combine
import Foundation

/// Owns debounce, generation, and stale-result rejection for the debug prediction slice.
@MainActor
final class SuggestionDebugModel: ObservableObject {
    @Published private(set) var state: SuggestionDebugState = .idle
    @Published private(set) var latestSuggestionPreview: String?
    @Published private(set) var latestError: String?
    @Published private(set) var latestLatencyMilliseconds: Int?
    @Published private(set) var latestStageMessage = "Idle"
    @Published private(set) var latestRequestPreview: String?
    @Published private(set) var latestPromptPreview: String?
    @Published private(set) var latestRawModelOutput: String?
    @Published private(set) var latestGenerationNumber: UInt64?

    private let permissionManager: PermissionManager
    private let focusModel: FocusTrackingModel
    private let inputMonitor: InputMonitor
    private let suggestionInserter: SuggestionInserter
    private let completionClient: LlamaCompletionClient
    private let contextBuffer: ContextBuffer
    private let configuration: SuggestionConfiguration

    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var latestWorkID: UInt64 = 0
    private var lastLoggedMessage: String?
    private var readyContext: FocusedInputContext?
    private var readyResult: SuggestionResult?

    init(
        permissionManager: PermissionManager,
        focusModel: FocusTrackingModel,
        inputMonitor: InputMonitor,
        suggestionInserter: SuggestionInserter,
        completionClient: LlamaCompletionClient,
        contextBuffer: ContextBuffer,
        configuration: SuggestionConfiguration
    ) {
        self.permissionManager = permissionManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.suggestionInserter = suggestionInserter
        self.completionClient = completionClient
        self.contextBuffer = contextBuffer
        self.configuration = configuration

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

        inputMonitor.onEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? false
        }

        inputMonitor.onSuppressedSyntheticInput = { [weak self] in
            self?.handleSuppressedSyntheticInput()
        }
    }

    func start() {
        reconcileWithCurrentEnvironment()
    }

    func stop() {
        cancelPredictionWork()
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
    }

    private func handlePermissionChange() {
        reconcileWithCurrentEnvironment()
    }

    private func handleFocusSnapshotChange(_ snapshot: FocusSnapshot) {
        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Matcha can react to typing.")
            return
        }

        switch snapshot.capability {
        case .supported:
            if let currentContext = contextBuffer.currentContext,
               let focusedContext = snapshot.context,
               currentContext.elementIdentifier != focusedContext.elementIdentifier {
                clearSuggestion(clearDiagnostics: true)
                state = .idle
            } else if case .disabled = state {
                latestError = nil
                state = .idle
            }

        case let .blocked(reason), let .unsupported(reason):
            disablePredictions(reason: reason)
        }
    }

    private func handleInputEvent(_ event: CapturedInputEvent) -> Bool {
        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Matcha can react to typing.")
            return false
        }

        if event.kind == .tab {
            return acceptCurrentSuggestion()
        }

        if event.shouldClearSuggestion {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
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
            message: "Ignored Matcha's own synthetic key event."
        )
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
        latestError = nil
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

    private func generateFromCurrentFocus(workID: UInt64) async {
        guard workID == latestWorkID else {
            return
        }

        // We intentionally re-read the latest focus snapshot here instead of trusting the earlier
        // key event, because the user may have switched apps or fields during the debounce window.
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Matcha can react to typing.")
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        guard !rawContext.precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSuggestion()
            state = .idle
            return
        }

        let context = contextBuffer.materialize(from: rawContext)
        let prompt = buildPrompt(from: context)
        let requestPreview = buildRequestPreview(prompt: prompt)
        latestGenerationNumber = context.generation
        latestRequestPreview = requestPreview
        latestPromptPreview = prompt
        latestRawModelOutput = nil
        let request = SuggestionRequest(
            context: context,
            prompt: prompt,
            generation: context.generation,
            maxPredictionTokens: configuration.maxPredictionTokens,
            temperature: configuration.temperature,
            topP: configuration.topP
        )

        state = .generating
        logStage(
            "generating",
            workID: workID,
            generation: context.generation,
            message: "Requesting a completion for \(context.elementIdentifier).",
            prompt: requestPreview
        )

        generationTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await completionClient.generateSuggestion(for: request)
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

    private func apply(result: SuggestionResult, workID: UInt64) async {
        guard workID == latestWorkID else {
            return
        }

        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Matcha can react to typing.")
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
            return
        }

        latestRawModelOutput = makeDebugPreview(result.rawText)

        guard !result.text.isEmpty else {
            clearSuggestion()
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

        latestSuggestionPreview = result.text
        latestLatencyMilliseconds = Int(result.latency * 1000)
        latestError = nil
        readyContext = liveContext
        readyResult = result
        state = .ready(text: result.text, latency: result.latency)
        logStage(
            "ready",
            workID: workID,
            generation: result.generation,
            message: "Accepted a non-empty normalized suggestion.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )
    }

    private func applyFailure(_ message: String, workID: UInt64) async {
        guard workID == latestWorkID else {
            return
        }

        clearSuggestion()
        latestError = message
        state = .failed(message)
        logStage("failed", workID: workID, generation: latestGenerationNumber, message: message)
    }

    private func reconcileWithCurrentEnvironment() {
        guard permissionManager.inputMonitoringGranted else {
            disablePredictions(reason: "Input Monitoring permission is required before Matcha can react to typing.")
            return
        }

        switch focusModel.snapshot.capability {
        case .supported:
            if case .disabled = state {
                latestError = nil
                state = .idle
            }
        case let .blocked(reason), let .unsupported(reason):
            disablePredictions(reason: reason)
        }
    }

    private func disablePredictions(reason: String) {
        cancelPredictionWork()
        contextBuffer.clear()
        clearSuggestion(clearDiagnostics: true)
        latestError = reason
        state = .disabled(reason)
        latestStageMessage = "Disabled: \(reason)"
    }

    private func clearSuggestion(clearDiagnostics: Bool = false) {
        latestSuggestionPreview = nil
        latestLatencyMilliseconds = nil
        readyContext = nil
        readyResult = nil

        if clearDiagnostics {
            latestRequestPreview = nil
            latestPromptPreview = nil
            latestRawModelOutput = nil
            latestGenerationNumber = nil
        }
    }

    private func cancelPredictionWork() {
        debounceTask?.cancel()
        generationTask?.cancel()
        debounceTask = nil
        generationTask = nil
        latestWorkID &+= 1
    }

    private func buildPrompt(from context: FocusedInputContext) -> String {
        // For the plain `/completion` rollback we only send text before the caret.
        // That keeps the payload minimal and matches the simpler baseline behavior.
        String(context.precedingText.suffix(configuration.maxPrefixCharacters))
    }

    private func nextWorkID() -> UInt64 {
        latestWorkID &+= 1
        return latestWorkID
    }

    private func buildRequestPreview(prompt: String) -> String {
        """
        POST /completion
        prompt: \(prompt.isEmpty ? "<empty>" : prompt)
        """
    }

    private func acceptCurrentSuggestion() -> Bool {
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            return passTabThrough(reason: "Input Monitoring permission is required before Matcha can accept Tab.")
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return passTabThrough(reason: snapshot.capability.summary)
        }

        guard case .ready = state, let readyResult, let readyContext else {
            return passTabThrough(reason: "Tab passed through because no valid suggestion was ready.")
        }

        guard rawContext.selection.length == 0 else {
            return passTabThrough(reason: "Tab passed through because text is currently selected.")
        }

        let liveContext = contextBuffer.materialize(from: rawContext)
        guard liveContext.elementIdentifier == readyContext.elementIdentifier else {
            return passTabThrough(reason: "Tab passed through because the focused field changed.")
        }

        guard liveContext.generation == readyResult.generation else {
            return passTabThrough(reason: "Tab passed through because the ready suggestion became stale.")
        }

        guard suggestionInserter.insert(readyResult.text) else {
            let message = suggestionInserter.lastErrorMessage ?? "Suggestion insertion failed."
            latestError = message
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            state = .idle
            logStage(
                "insert-failed",
                workID: latestWorkID,
                generation: readyResult.generation,
                message: message,
                normalizedOutput: readyResult.text
            )
            return false
        }

        latestError = nil
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        focusModel.refreshNow()
        state = .idle
        logStage(
            "tab-accepted",
            workID: latestWorkID,
            generation: readyResult.generation,
            message: "Inserted the ready suggestion and consumed Tab.",
            normalizedOutput: readyResult.text
        )
        return true
    }

    private func passTabThrough(reason: String) -> Bool {
        let generation = latestGenerationNumber
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        latestError = nil
        state = .idle
        logStage(
            "tab-passed-through",
            workID: latestWorkID,
            generation: generation,
            message: reason
        )
        return false
    }

    private func logStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64? = nil,
        message: String,
        prompt: String? = nil,
        rawOutput: String? = nil,
        normalizedOutput: String? = nil
    ) {
        latestStageMessage = message

        var parts = [
            "[Suggestion]",
            "stage=\(stage)",
            "work=\(workID)"
        ]

        if let generation {
            parts.append("generation=\(generation)")
        }

        parts.append("message=\(message)")

        if let prompt {
            parts.append("prompt=\(makeDebugPreview(prompt))")
        }

        if let rawOutput {
            parts.append("raw=\(makeDebugPreview(rawOutput))")
        }

        if let normalizedOutput {
            parts.append("normalized=\(makeDebugPreview(normalizedOutput))")
        }

        let line = parts.joined(separator: " ")
        guard line != lastLoggedMessage else {
            return
        }

        lastLoggedMessage = line
        print(line)
    }

    private func makeDebugPreview(_ text: String) -> String {
        if text.isEmpty {
            return "<empty>"
        }

        let escaped = text.debugDescription
        if escaped.count > 240 {
            return String(escaped.prefix(240)) + "..."
        }

        return escaped
    }
}
