import Combine
import Foundation
import LlamaSwift

private struct PreparedLlamaRuntime: Sendable {
    let resolvedRuntime: ResolvedLlamaRuntime
    let contextWindowTokens: Int
    let batchSize: Int
    let threadCount: Int
    let gpuLayerCount: Int
    let backendName: String
}

/// Owns the long-lived model and hides the raw llama.cpp lifecycle behind one serialized actor.
/// Starting with "one loaded model, fresh context per request" keeps correctness simple before
/// we add any prefix-cache or context reuse optimizations.
private actor LlamaRuntimeCore {
    private var backendInitialized = false
    private var model: OpaquePointer?
    private var preparedRuntime: PreparedLlamaRuntime?

    func prepare(
        resolvedRuntime: ResolvedLlamaRuntime,
        configuration: LlamaRuntimeConfiguration
    ) throws -> PreparedLlamaRuntime {
        if let preparedRuntime,
           preparedRuntime.resolvedRuntime.modelFileURL == resolvedRuntime.modelFileURL
        {
            return preparedRuntime
        }

        if preparedRuntime != nil {
            shutdown()
        }

        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = configuration.gpuLayerCount
        modelParams.use_mmap = true
        modelParams.use_mlock = false

        guard let loadedModel = resolvedRuntime.modelFileURL.path.withCString({
            llama_model_load_from_file($0, modelParams)
        }) else {
            throw LlamaRuntimeError.unavailable("Unable to load \(resolvedRuntime.modelDisplayName) with llama.cpp.")
        }

        model = loadedModel

        let preparedRuntime = PreparedLlamaRuntime(
            resolvedRuntime: resolvedRuntime,
            contextWindowTokens: Int(configuration.contextWindowTokens),
            batchSize: Int(configuration.batchSize),
            threadCount: max(1, ProcessInfo.processInfo.activeProcessorCount),
            gpuLayerCount: Int(configuration.gpuLayerCount),
            backendName: "llama.swift (llama.cpp in-process)"
        )
        self.preparedRuntime = preparedRuntime
        return preparedRuntime
    }

    func generate(
        prompt: String,
        maxPredictionTokens: Int,
        temperature: Double,
        topP: Double
    ) throws -> String {
        guard let preparedRuntime else {
            throw LlamaRuntimeError.unavailable("The llama model is not loaded.")
        }

        guard let model else {
            throw LlamaRuntimeError.unavailable("The llama model is not loaded.")
        }

        let context = try makeContext(
            model: model,
            contextWindowTokens: preparedRuntime.contextWindowTokens,
            batchSize: preparedRuntime.batchSize,
            threadCount: preparedRuntime.threadCount
        )
        defer { llama_free(context) }

        guard let vocab = llama_model_get_vocab(model) else {
            throw LlamaRuntimeError.generationFailed("Unable to access the model vocabulary.")
        }

        let promptTokens = try tokenize(prompt, vocab: vocab)
        try decodePrompt(promptTokens, in: context, batchCapacity: preparedRuntime.batchSize)

        let sampler = try makeSampler(temperature: temperature, topP: topP)
        defer { llama_sampler_free(sampler) }

        var generatedText = ""
        var position = Int32(promptTokens.count)

        for _ in 0 ..< maxPredictionTokens {
            let nextToken = llama_sampler_sample(sampler, context, -1)
            if nextToken == llama_vocab_eos(vocab) || llama_vocab_is_eog(vocab, nextToken) {
                break
            }

            let piece = pieceString(for: nextToken, vocab: vocab)
            generatedText += piece
            llama_sampler_accept(sampler, nextToken)

            if generatedText.contains("\n") {
                break
            }

            try decodeToken(nextToken, position: position, in: context)
            position += 1
        }

        return generatedText
    }

    func shutdown() {
        if let model {
            llama_model_free(model)
            self.model = nil
        }

        preparedRuntime = nil

        if backendInitialized {
            llama_backend_free()
            backendInitialized = false
        }
    }

    private func makeContext(
        model: OpaquePointer,
        contextWindowTokens: Int,
        batchSize: Int,
        threadCount: Int
    ) throws -> OpaquePointer {
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextWindowTokens)
        contextParams.n_batch = UInt32(batchSize)
        contextParams.n_ubatch = UInt32(batchSize)
        contextParams.n_seq_max = 1
        contextParams.n_threads = Int32(threadCount)
        contextParams.n_threads_batch = Int32(threadCount)
        contextParams.offload_kqv = true

        guard let context = llama_init_from_model(model, contextParams) else {
            throw LlamaRuntimeError.generationFailed("Unable to create a llama context.")
        }

        return context
    }

    private func tokenize(_ prompt: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8Count = max(prompt.utf8.count, 1)
        var capacity = utf8Count + 8
        let addSpecial = llama_vocab_get_add_bos(vocab)

        while true {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let tokenCount = prompt.withCString { promptCString in
                llama_tokenize(
                    vocab,
                    promptCString,
                    Int32(prompt.utf8.count),
                    &tokens,
                    Int32(tokens.count),
                    addSpecial,
                    false
                )
            }

            if tokenCount > 0 {
                return Array(tokens.prefix(Int(tokenCount)))
            }

            if tokenCount == 0 {
                throw LlamaRuntimeError.generationFailed("Tokenization returned no prompt tokens.")
            }

            capacity = max(capacity * 2, Int(-tokenCount))
        }
    }

    private func decodePrompt(
        _ promptTokens: [llama_token],
        in context: OpaquePointer,
        batchCapacity: Int
    ) throws {
        var batch = llama_batch_init(Int32(max(promptTokens.count, batchCapacity)), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(promptTokens.count)

        for index in promptTokens.indices {
            batch.token[index] = promptTokens[index]
            batch.pos[index] = Int32(index)
            batch.n_seq_id[index] = 1

            if let seqIDs = batch.seq_id, let seqID = seqIDs[index] {
                seqID[0] = 0
            }

            batch.logits[index] = 0
        }

        if batch.n_tokens > 0 {
            batch.logits[Int(batch.n_tokens) - 1] = 1
        }

        guard llama_decode(context, batch) == 0 else {
            throw LlamaRuntimeError.generationFailed("llama_decode failed while evaluating the prompt.")
        }
    }

    private func decodeToken(
        _ token: llama_token,
        position: Int32,
        in context: OpaquePointer
    ) throws {
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = 1
        batch.token[0] = token
        batch.pos[0] = position
        batch.n_seq_id[0] = 1

        if let seqIDs = batch.seq_id, let seqID = seqIDs[0] {
            seqID[0] = 0
        }

        batch.logits[0] = 1

        guard llama_decode(context, batch) == 0 else {
            throw LlamaRuntimeError.generationFailed("llama_decode failed while generating a continuation.")
        }
    }

    private func makeSampler(
        temperature: Double,
        topP: Double
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(params) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the llama sampler chain.")
        }

        if topP > 0 && topP < 1 {
            guard let topPSampler = llama_sampler_init_top_p(Float(topP), 1) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the top-p sampler.")
            }

            llama_sampler_chain_add(sampler, topPSampler)
        }

        if temperature > 0 {
            guard let temperatureSampler = llama_sampler_init_temp(Float(temperature)) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the temperature sampler.")
            }
            llama_sampler_chain_add(sampler, temperatureSampler)

            guard let distributionSampler = llama_sampler_init_dist(UInt32.random(in: UInt32.min ... UInt32.max)) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the distribution sampler.")
            }
            llama_sampler_chain_add(sampler, distributionSampler)
        } else {
            guard let greedySampler = llama_sampler_init_greedy() else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the greedy sampler.")
            }
            llama_sampler_chain_add(sampler, greedySampler)
        }

        return sampler
    }

    private func pieceString(for token: llama_token, vocab: OpaquePointer) -> String {
        var bufferLength = 32

        while true {
            var buffer = [CChar](repeating: 0, count: bufferLength)
            let written = llama_token_to_piece(
                vocab,
                token,
                &buffer,
                Int32(buffer.count),
                0,
                false
            )

            if written < 0 {
                bufferLength = max(bufferLength * 2, Int(-written) + 1)
                continue
            }

            let bytes = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Publishes runtime diagnostics for the UI and delegates expensive inference work to the core actor.
@MainActor
final class LlamaRuntimeManager: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState = .idle
    @Published private(set) var diagnostics = LlamaRuntimeDiagnostics()

    private let configuration: LlamaRuntimeConfiguration
    private let runtimeLocator: BundledRuntimeLocator
    private let core: LlamaRuntimeCore
    private var startupTask: Task<PreparedLlamaRuntime, Error>?
    private var cachedRuntime: PreparedLlamaRuntime?

    convenience init() {
        self.init(
            configuration: .default,
            runtimeLocator: BundledRuntimeLocator()
        )
    }

    init(
        configuration: LlamaRuntimeConfiguration,
        runtimeLocator: BundledRuntimeLocator
    ) {
        self.configuration = configuration
        self.runtimeLocator = runtimeLocator
        core = LlamaRuntimeCore()
    }

    func prepare() async throws {
        _ = try await preparedRuntime()
    }

    func generate(
        prompt: String,
        maxPredictionTokens: Int,
        temperature: Double,
        topP: Double
    ) async throws -> String {
        _ = try await preparedRuntime()

        do {
            return try await core.generate(
                prompt: prompt,
                maxPredictionTokens: maxPredictionTokens,
                temperature: temperature,
                topP: topP
            )
        } catch is CancellationError {
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            diagnostics.lastError = error.localizedDescription
            throw error
        } catch {
            let runtimeError = LlamaRuntimeError.generationFailed(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            throw runtimeError
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        cachedRuntime = nil

        Task {
            await core.shutdown()
        }

        diagnostics.lastLoadStatus = "Stopped"
        state = .idle
    }

    private func preparedRuntime() async throws -> PreparedLlamaRuntime {
        if let cachedRuntime {
            return cachedRuntime
        }

        if let startupTask {
            return try await startupTask.value
        }

        state = .starting("Initializing the in-process llama runtime.")
        diagnostics.lastError = nil
        diagnostics.lastLoadStatus = "Starting"
        let resolvedRuntime: ResolvedLlamaRuntime

        do {
            resolvedRuntime = try runtimeLocator.resolve(configuration: configuration)
        } catch {
            let runtimeError = LlamaRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }

        let startupTask = Task { [core, configuration] in
            try await core.prepare(
                resolvedRuntime: resolvedRuntime,
                configuration: configuration
            )
        }
        self.startupTask = startupTask
        state = .loading("Loading the model into memory.")

        do {
            let preparedRuntime = try await startupTask.value
            cachedRuntime = preparedRuntime
            apply(preparedRuntime)
            self.startupTask = nil
            return preparedRuntime
        } catch is CancellationError {
            self.startupTask = nil
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            self.startupTask = nil
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(error.localizedDescription)
            throw error
        } catch {
            self.startupTask = nil
            let runtimeError = LlamaRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    private func apply(_ preparedRuntime: PreparedLlamaRuntime) {
        diagnostics.runtimeDirectoryPath = preparedRuntime.resolvedRuntime.runtimeDirectoryURL.path
        diagnostics.modelFilePath = preparedRuntime.resolvedRuntime.modelFileURL.path
        diagnostics.backendName = preparedRuntime.backendName
        diagnostics.contextWindowTokens = preparedRuntime.contextWindowTokens
        diagnostics.batchSize = preparedRuntime.batchSize
        diagnostics.threadCount = preparedRuntime.threadCount
        diagnostics.gpuLayerCount = preparedRuntime.gpuLayerCount
        diagnostics.lastLoadStatus = "Loaded"
        diagnostics.lastError = nil

        state = .ready("Loaded \(preparedRuntime.resolvedRuntime.modelDisplayName) in-process.")
    }
}
