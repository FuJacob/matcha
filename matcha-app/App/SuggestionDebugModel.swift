import Combine
import CoreGraphics
import Foundation

/// Owns debounce, generation, stale-result rejection, and the ghost-text overlay lifecycle.
/// The important architectural choice is that overlay visibility is derived from the same
/// canonical ready suggestion state that powers `Tab` acceptance.
@MainActor
final class SuggestionDebugModel: ObservableObject {
    @Published private(set) var state: SuggestionDebugState = .idle
    @Published private(set) var overlayState: OverlayState = .hidden(reason: "Overlay idle.")
    @Published private(set) var latestSuggestionPreview: String?
    @Published private(set) var latestLatencyMilliseconds: Int?
    @Published private(set) var latestStageMessage = "Idle"
    @Published private(set) var latestOverlayMessage = "Overlay idle."
    @Published private(set) var latestRequestPreview: String?
    @Published private(set) var latestPromptPreview: String?
    @Published private(set) var latestRawModelOutput: String?
    @Published private(set) var latestGenerationNumber: UInt64?

    private let permissionManager: PermissionManager
    private let focusModel: FocusTrackingModel
    private let inputMonitor: InputMonitor
    private let overlayController: OverlayController
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
        overlayController: OverlayController,
        suggestionInserter: SuggestionInserter,
        completionClient: LlamaCompletionClient,
        contextBuffer: ContextBuffer,
        configuration: SuggestionConfiguration
    ) {
        self.permissionManager = permissionManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.overlayController = overlayController
        self.suggestionInserter = suggestionInserter
        self.completionClient = completionClient
        self.contextBuffer = contextBuffer
        self.configuration = configuration
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

    func start() {
        reconcileWithCurrentEnvironment()
    }

    func stop() {
        cancelPredictionWork()
        hideOverlay(reason: "Overlay hidden because Matcha stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
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

        if let currentContext = contextBuffer.currentContext,
           currentContext.elementIdentifier != focusedContext.elementIdentifier {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because the focused field changed.")
            state = .idle
        } else if case .disabled = state {
            state = .idle
        }

        reconcileReadySuggestion(with: snapshot)
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
            hideOverlay(reason: "Overlay hidden because there is no text before the caret.")
            state = .idle
            return
        }

        let context = contextBuffer.materialize(from: rawContext)
        let prompt = buildPrompt(from: context)
        let requestPreview = buildRequestPreview()
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
            request: requestPreview,
            prompt: prompt
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

        latestSuggestionPreview = result.text
        latestLatencyMilliseconds = Int(result.latency * 1000)
        readyContext = liveContext
        readyResult = result
        state = .ready(text: result.text, latency: result.latency)
        presentOverlay(text: result.text, at: liveContext.caretRect)
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
        hideOverlay(reason: "Overlay hidden because generation failed.")
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
                state = .idle
            }

        case let .blocked(reason), let .unsupported(reason):
            disablePredictions(reason: reason)
        }
    }

    private func reconcileReadySuggestion(with snapshot: FocusSnapshot) {
        guard case .ready = state, let readyContext, let readyResult else {
            if overlayState.isVisible {
                hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
            }
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            invalidateReadySuggestion(reason: snapshot.capability.summary)
            return
        }

        let liveContext = contextBuffer.materialize(from: rawContext)

        guard liveContext.elementIdentifier == readyContext.elementIdentifier else {
            invalidateReadySuggestion(reason: "Overlay hidden because the focused field changed.")
            return
        }

        guard liveContext.contentSignature == readyContext.contentSignature else {
            invalidateReadySuggestion(reason: "Overlay hidden because the text or caret moved.")
            return
        }

        guard liveContext.generation == readyResult.generation else {
            invalidateReadySuggestion(reason: "Overlay hidden because the ready suggestion became stale.")
            return
        }

        guard liveContext.selection.length == 0 else {
            invalidateReadySuggestion(reason: "Overlay hidden because text is selected.")
            return
        }

        self.readyContext = liveContext
        presentOverlay(text: readyResult.text, at: liveContext.caretRect)
    }

    private func invalidateReadySuggestion(reason: String) {
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .idle
    }

    private func disablePredictions(reason: String) {
        cancelPredictionWork()
        contextBuffer.clear()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
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
        let prefix = String(context.precedingText.suffix(configuration.maxPrefixCharacters))
        let suffix = String(context.trailingText.prefix(configuration.maxSuffixCharacters))

        // Small local models follow a direct task description better than a raw prefix dump.
        // We still ask for plain continuation text, but we make the contract explicit.
        return """
        Your only job is to predict the exact next characters or words that seamlessly continue the user's text.

        CRITICAL RULES:
        1. Output ONLY the raw continuation text.
        2. Do not explain anything.
        3. Do not add quotes, labels, or markdown.
        4. Keep the continuation short and natural.

        Text before the cursor:
        \(prefix)

        Text after the cursor:
        \(suffix)

        Continuation: 
        """
    }

    private func nextWorkID() -> UInt64 {
        latestWorkID &+= 1
        return latestWorkID
    }

    private func buildRequestPreview() -> String {
        """
        POST /completion
        n_predict: \(configuration.maxPredictionTokens)
        temperature: \(configuration.temperature)
        top_p: \(configuration.topP)
        stop: ["\\n"]
        cache: disabled
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

        guard overlayMatchesReadySuggestion(text: readyResult.text) else {
            return passTabThrough(reason: "Tab passed through because no visible ghost text matched the ready suggestion.")
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
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because suggestion insertion failed.")
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

        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because Tab accepted the current suggestion.")
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

    private func overlayMatchesReadySuggestion(text: String) -> Bool {
        guard case let .visible(visibleText, _) = overlayState else {
            return false
        }

        return visibleText == text
    }

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

        var parts = [
            "[Suggestion]",
            "stage=\(stage)",
            "work=\(workID)"
        ]

        if let generation {
            parts.append("generation=\(generation)")
        }

        parts.append("message=\(message)")

        if let request {
            parts.append("request=\(makeDebugPreview(request))")
        }

        if let prompt {
            parts.append("prompt=\(makeDebugPreview(prompt))")
        }

        if let rawOutput {
            parts.append("raw=\(makeDebugPreview(rawOutput))")
        }

        if let normalizedOutput {
            parts.append("normalized=\(makeDebugPreview(normalizedOutput))")
        }

        let summaryLine = parts.joined(separator: " ")
        logLine(summaryLine)

        if let request {
            logTextBlock(
                kind: "request",
                stage: stage,
                workID: workID,
                generation: generation,
                text: request
            )
        }

        if let prompt {
            logTextBlock(
                kind: "prompt",
                stage: stage,
                workID: workID,
                generation: generation,
                text: prompt
            )
        }

        if let rawOutput {
            logTextBlock(
                kind: "raw-output",
                stage: stage,
                workID: workID,
                generation: generation,
                text: rawOutput
            )
        }

        if let normalizedOutput {
            logTextBlock(
                kind: "normalized-output",
                stage: stage,
                workID: workID,
                generation: generation,
                text: normalizedOutput
            )
        }
    }

    private func logOverlay(_ stage: String, message: String, text: String? = nil, caretRect: CGRect? = nil) {
        var parts = [
            "[Overlay]",
            "stage=\(stage)",
            "message=\(message)"
        ]

        if let text {
            parts.append("text=\(makeDebugPreview(text))")
        }

        if let caretRect {
            parts.append(
                "rect=(\(Int(caretRect.minX)),\(Int(caretRect.minY)),\(Int(caretRect.width)),\(Int(caretRect.height)))"
            )
        }

        logLine(parts.joined(separator: " "))
    }

    private func logLine(_ line: String) {
        guard line != lastLoggedMessage else {
            return
        }

        lastLoggedMessage = line
        print(line)
    }

    /// Compact one-line logs are good for scanning, but debugging prompts needs the exact payload.
    /// We print full blocks here so you can compare Matcha's request with a manual curl byte-for-byte.
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
