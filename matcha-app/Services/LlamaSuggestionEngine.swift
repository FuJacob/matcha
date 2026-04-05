import Foundation

/// Keeps prompt normalization separate from the raw llama runtime.
/// That separation matters because prompt strategy changes far more often than model lifecycle code.
@MainActor
final class LlamaSuggestionEngine {
    private let runtimeManager: LlamaRuntimeManager

    init(runtimeManager: LlamaRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        do {
            let startTime = Date()
            let rawSuggestion = try await runtimeManager.generate(
                prompt: request.prompt,
                maxPredictionTokens: request.maxPredictionTokens,
                temperature: request.temperature,
                topP: request.topP
            )
            try Task.checkCancellation()

            let normalizedSuggestion = normalizeSuggestion(rawSuggestion, for: request)
            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: Date().timeIntervalSince(startTime),
                finishReason: "llama.swift"
            )
        } catch is CancellationError {
            throw SuggestionClientError.cancelled
        } catch let error as LlamaRuntimeError {
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    private func normalizeSuggestion(_ rawSuggestion: String, for request: SuggestionRequest) -> String {
        var normalized = rawSuggestion.replacingOccurrences(of: "\r", with: "")

        if !request.prompt.isEmpty, normalized.hasPrefix(request.prompt) {
            normalized.removeFirst(request.prompt.count)
        }

        if let firstLine = normalized.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            normalized = String(firstLine)
        }

        normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))

        if normalized.hasPrefix(request.context.trailingText), !request.context.trailingText.isEmpty {
            return ""
        }

        if normalized.count > 120 {
            normalized = String(normalized.prefix(120))
        }

        return normalized.trimmingCharacters(in: .newlines)
    }
}
