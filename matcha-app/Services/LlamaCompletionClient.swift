import Foundation

private struct InfillRequestBody: Encodable {
    let inputPrefix: String
    let inputSuffix: String
    let prompt: String
    let idSlot: Int
    let cachePrompt: Bool
    let stream: Bool
    let nPredict: Int
    let temperature: Double
    let topP: Double
    let stop: [String]

    enum CodingKeys: String, CodingKey {
        case inputPrefix = "input_prefix"
        case inputSuffix = "input_suffix"
        case prompt
        case idSlot = "id_slot"
        case cachePrompt = "cache_prompt"
        case stream
        case nPredict = "n_predict"
        case temperature
        case topP = "top_p"
        case stop
    }
}

private struct CompletionResponseBody: Decodable {
    let content: String
}

/// Talks to the shared bundled `llama-server` runtime over localhost.
/// Keeping this boundary narrow makes it easy to change prompt or transport logic later.
@MainActor
final class LlamaCompletionClient {
    private let serverManager: LlamaServerManager
    private let session: URLSession

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        do {
            let startTime = Date()
            let baseURL = try await serverManager.start()
            try Task.checkCancellation()

            let suggestion = try await fetchCompletion(baseURL: baseURL, request: request)
            try Task.checkCancellation()

            let normalizedSuggestion = normalizeSuggestion(suggestion, for: request)

            return SuggestionResult(
                generation: request.generation,
                rawText: suggestion,
                text: normalizedSuggestion,
                latency: Date().timeIntervalSince(startTime),
                finishReason: "llama-server"
            )
        } catch is CancellationError {
            throw SuggestionClientError.cancelled
        } catch let error as LlamaServerError {
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    private func fetchCompletion(baseURL: URL, request: SuggestionRequest) async throws -> String {
        let body = InfillRequestBody(
            inputPrefix: request.inputPrefix,
            inputSuffix: request.inputSuffix,
            prompt: request.prompt,
            idSlot: 0,
            cachePrompt: true,
            stream: false,
            nPredict: request.maxPredictionTokens,
            temperature: request.temperature,
            topP: request.topP,
            stop: ["\n"]
        )

        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)

        var urlRequest = URLRequest(url: baseURL.appending(path: "infill"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SuggestionClientError.generationFailed("Completion request returned an invalid response.")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw SuggestionClientError.generationFailed(
                bodyText.isEmpty ? "Completion request failed with HTTP \(httpResponse.statusCode)." : bodyText
            )
        }

        do {
            let decoded = try JSONDecoder().decode(CompletionResponseBody.self, from: data)
            return decoded.content
        } catch {
            throw SuggestionClientError.generationFailed(
                "Unable to decode llama-server completion response: \(error.localizedDescription)"
            )
        }
    }

    private func normalizeSuggestion(_ rawSuggestion: String, for request: SuggestionRequest) -> String {
        var normalized = rawSuggestion.replacingOccurrences(of: "\r", with: "")

        // Some local models echo part of the prompt. Stripping that here keeps the UI focused on
        // the predicted continuation instead of transport noise.
        if !request.prompt.isEmpty, let echoedPromptRange = normalized.range(of: request.prompt) {
            normalized = String(normalized[echoedPromptRange.upperBound...])
        }

        if let firstLine = normalized.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            normalized = String(firstLine)
        }

        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))

        if normalized.count > 120 {
            normalized = String(normalized.prefix(120))
        }

        if !request.context.trailingText.isEmpty, normalized == request.context.trailingText {
            return ""
        }

        if !normalized.isEmpty, !request.context.trailingText.isEmpty, request.context.trailingText.hasPrefix(normalized) {
            return ""
        }

        return normalized
    }
}
