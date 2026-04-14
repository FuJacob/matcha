import CoreGraphics
import Foundation

/// File overview:
/// Suggestion acceptance, live-session advancement, overlay presentation, and debug logging.
/// This is the "user sees it or commits it" end of the coordinator.
extension SuggestionCoordinator {
    // MARK: - Acceptance and Session Reconciliation

    /// Accepts the current suggestion only if the field, generation, and visible overlay still match.
    func acceptCurrentSuggestion() -> Bool {
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            return passTabThrough(reason: "Input Monitoring permission is required before Tabby can accept Tab.")
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return passTabThrough(reason: snapshot.capability.summary)
        }

        guard case .ready = state else {
            return passTabThrough(reason: "Tab passed through because no valid suggestion was ready.")
        }

        let acceptancePreparation = interactionState.prepareAcceptance(
            from: rawContext,
            overlayState: overlayState
        )
        let liveContext: FocusedInputContext
        let sessionForAcceptance: ActiveSuggestionSession
        let acceptedChunk: String
        switch acceptancePreparation {
        case let .ready(preparedLiveContext, preparedSession, preparedAcceptedChunk):
            liveContext = preparedLiveContext
            sessionForAcceptance = preparedSession
            acceptedChunk = preparedAcceptedChunk

        case let .invalid(reason):
            return passTabThrough(reason: reason)
        }

        guard suggestionInserter.insert(acceptedChunk) else {
            let message = suggestionInserter.lastErrorMessage ?? "Suggestion insertion failed."
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because suggestion insertion failed.")
            state = .idle
            logStage(
                "insert-failed",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: message,
                normalizedOutput: acceptedChunk
            )
            return false
        }

        recordAcceptedWords(from: acceptedChunk)

        cancelPredictionWork()

        switch interactionState.commitAcceptedChunk(
            acceptedChunk,
            liveContext: liveContext,
            session: sessionForAcceptance
        ) {
        case .exhausted:
            latestGenerationNumber = liveContext.generation
            clearSuggestion(clearDiagnostics: false)
            hideOverlay(reason: "Overlay hidden because Tab accepted the final suggestion chunk.")
            latestAcceptanceAction = "Accepted final chunk with Tab."
            state = .idle
            logStage(
                "tab-accepted-final-chunk",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: "Inserted the final suggestion chunk and queued a refresh.",
                normalizedOutput: acceptedChunk
            )
            schedulePrediction()
            return true

        case let .advanced(advancedSession, _):
            latestGenerationNumber = liveContext.generation
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
                workID: currentWorkID,
                generation: liveContext.generation,
                message: "Inserted the next suggestion chunk and kept the remaining tail active.",
                normalizedOutput: acceptedChunk
            )
            return true
        }
    }

    /// Returns control of `Tab` to the host app and clears stale suggestion UI.
    func passTabThrough(reason: String) -> Bool {
        let generation = latestGenerationNumber
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .idle
        logStage(
            "tab-passed-through",
            workID: currentWorkID,
            generation: generation,
            message: reason
        )
        return false
    }

    /// Advances the active session from the user's directly typed characters when they match the
    /// next expected tail exactly. This avoids a wasteful regeneration for text the user already
    /// committed to the field themselves.
    func advanceActiveSessionIfTypedCharactersMatch(_ typedCharacters: String, session: ActiveSuggestionSession) -> Bool {
        guard let advancedSession = interactionState.advanceIfTypedCharactersMatch(
            typedCharacters,
            expectedSession: session
        ) else {
            return false
        }

        cancelPredictionWork()
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
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "User typing matched the active suggestion tail exactly.",
            normalizedOutput: advancedSession.remainingText
        )
        return true
    }

    func invalidateActiveSuggestion(
        reason: String,
        clearDiagnostics: Bool = true
    ) {
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: clearDiagnostics)
        hideOverlay(reason: reason)
        state = .idle
    }

    func completeActiveSuggestion(
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
        logStage(stage, workID: currentWorkID, generation: generation, message: message)

        if scheduleNextPrediction {
            schedulePrediction()
        }
    }

    func applySessionDiagnostics(_ session: ActiveSuggestionSession, acceptanceAction: String?) {
        latestSuggestionPreview = session.remainingText
        latestFullSuggestionPreview = session.fullText
        latestRemainingSuggestionPreview = session.remainingText
        latestAcceptedCharacterCount = session.acceptedCount
        latestRemainingCharacterCount = session.remainingCount
        if let acceptanceAction {
            latestAcceptanceAction = acceptanceAction
        }
    }

    /// Updates the global productivity counter from text accepted via Tab.
    func recordAcceptedWords(from acceptedChunk: String) {
        let acceptedWordCount = SuggestionSessionReconciler.acceptedWordCount(in: acceptedChunk)
        guard acceptedWordCount > 0 else {
            return
        }

        totalTabAcceptedWordCount += acceptedWordCount
        userDefaults.set(totalTabAcceptedWordCount, forKey: Self.totalTabAcceptedWordCountDefaultsKey)
    }

    // MARK: - Overlay and Logging

    func presentOverlay(text: String, at caretRect: CGRect) {
        if let message = overlayPresenter.present(text: text, at: caretRect, previousState: overlayState) {
            latestOverlayMessage = message
        }
    }

    func hideOverlay(reason: String) {
        latestOverlayMessage = overlayPresenter.hide(reason: reason)
    }

    func logStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64? = nil,
        message: String,
        prompt: String? = nil,
        rawOutput: String? = nil,
        normalizedOutput: String? = nil
    ) {
        latestStageMessage = message
        logger.logStage(
            stage,
            workID: workID,
            generation: generation,
            message: message,
            prompt: prompt,
            rawOutput: rawOutput,
            normalizedOutput: normalizedOutput
        )
    }
}
