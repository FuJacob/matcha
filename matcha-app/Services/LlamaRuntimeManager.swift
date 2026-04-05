import Combine
import Foundation
import LlamaSwift

/// File overview:
/// Owns the in-process llama.cpp runtime. The private actor handles raw model/context lifecycle
/// and generation, while the observable manager republishes bootstrap state and diagnostics to the app.
///
private let llamaSilencedLogCallback: ggml_log_callback = { _, _, _ in }

/// Immutable runtime metadata captured after a model has been successfully prepared.
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
    private static var isNativeLoggingSilenced = false
    private var backendInitialized = false
    private var model: OpaquePointer?
    private var preparedRuntime: PreparedLlamaRuntime?

    /// Loads the requested model once and records the runtime characteristics needed for diagnostics.
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
            if !Self.isNativeLoggingSilenced {
                llama_log_set(llamaSilencedLogCallback, nil)
                Self.isNativeLoggingSilenced = true
            }
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

    /// Creates a fresh inference context, evaluates the prompt, and samples a short completion.
    func generate(
        prompt: String,
        maxPredictionTokens: Int,
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double
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

        let sampler = try makeSampler(
            temperature: temperature, 
            topK: topK, 
            topP: topP, 
            minP: minP, 
            repetitionPenalty: repetitionPenalty
        )
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

    /// Frees any loaded model/backend state owned by the actor.
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

    /// Builds a fresh llama context for one generation request so requests remain isolated.
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

    /// Tokenizes the prompt using the loaded model vocabulary and preserves special tokens.
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

    /// Feeds the prompt tokens through the context so sampling can begin from the final prompt state.
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

    /// Advances the context by one sampled token so generation can continue autoregressively.
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

    /// Assembles the sampler chain that controls temperature, nucleus sampling, and repetition behavior.
    private func makeSampler(
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(params) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the llama sampler chain.")
        }

        if repetitionPenalty > 1.0 {
            guard let penaltySampler = llama_sampler_init_penalties(64, Float(repetitionPenalty), 1.0, 1.0) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the repetition penalty sampler.")
            }
            llama_sampler_chain_add(sampler, penaltySampler)
        }

        if temperature > 0 {
            guard let temperatureSampler = llama_sampler_init_temp(Float(temperature)) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the temperature sampler.")
            }
            llama_sampler_chain_add(sampler, temperatureSampler)

            if topK > 0 {
                guard let topKSampler = llama_sampler_init_top_k(Int32(topK)) else {
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the top-k sampler.")
                }
                llama_sampler_chain_add(sampler, topKSampler)
            }

            if minP > 0 && minP < 1 {
                guard let minPSampler = llama_sampler_init_min_p(Float(minP), 1) else {
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the min-p sampler.")
                }
                llama_sampler_chain_add(sampler, minPSampler)
            }

            if topP > 0 && topP < 1 {
                guard let topPSampler = llama_sampler_init_top_p(Float(topP), 1) else {
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the top-p sampler.")
                }
                llama_sampler_chain_add(sampler, topPSampler)
            }

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

    /// Converts one sampled token back into its text piece representation.
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
    let availableModels: [RuntimeModelOption]
    private var startupTask: Task<PreparedLlamaRuntime, Error>?
    private var startupModelFilename: String?
    private var cachedRuntime: PreparedLlamaRuntime?
    private var selectedModelFilename: String?

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
        availableModels = runtimeLocator.availableModels(configuration: configuration)
        selectedModelFilename = availableModels.first?.filename
        core = LlamaRuntimeCore()
    }

    /// Records which discovered model should be loaded when preparation starts.
    /// This keeps persisted UI state separate from the runtime loading lifecycle.
    func configureSelectedModel(filename: String?) {
        selectedModelFilename = normalizedModelFilename(filename)
    }

    /// Ensures the selected bundled model is resolved and prepared before any generation requests run.
    func prepare() async throws {
        _ = try await preparedRuntime()
    }

    /// Reloads the runtime in place with a newly selected bundled model.
    /// The manager instance stays alive; only the loaded model changes.
    func selectModel(filename: String) async throws {
        guard let normalizedFilename = normalizedModelFilename(filename) else {
            let error = LlamaRuntimeError.unavailable("The bundled model \(filename) is unavailable.")
            diagnostics.lastError = error.localizedDescription
            throw error
        }

        selectedModelFilename = normalizedFilename

        if cachedRuntime?.resolvedRuntime.modelFileURL.lastPathComponent == normalizedFilename {
            return
        }

        startupTask?.cancel()
        startupTask = nil
        startupModelFilename = nil
        cachedRuntime = nil

        _ = try await preparedRuntime()
    }

    /// Forwards one generation request into the serialized runtime actor after ensuring preparation.
    func generate(
        prompt: String,
        maxPredictionTokens: Int,
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double
    ) async throws -> String {
        _ = try await preparedRuntime()

        do {
            return try await core.generate(
                prompt: prompt,
                maxPredictionTokens: maxPredictionTokens,
                temperature: temperature,
                topK: topK,
                topP: topP,
                minP: minP,
                repetitionPenalty: repetitionPenalty
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

    /// Cancels any retained prepared runtime and asks the actor to release backend resources.
    func stop() {
        startupTask?.cancel()
        startupTask = nil
        startupModelFilename = nil
        cachedRuntime = nil

        Task {
            await core.shutdown()
        }

        diagnostics.lastLoadStatus = "Stopped"
        state = .idle
    }

    /// Returns cached runtime metadata when available or performs one full preparation flow otherwise.
    private func preparedRuntime() async throws -> PreparedLlamaRuntime {
        let resolvedRuntime = try resolveSelectedRuntime()
        let requestedModelFilename = resolvedRuntime.modelFileURL.lastPathComponent

        if let cachedRuntime,
           cachedRuntime.resolvedRuntime.modelFileURL == resolvedRuntime.modelFileURL
        {
            return cachedRuntime
        }

        if let startupTask {
            if startupModelFilename == requestedModelFilename {
                return try await awaitPreparedRuntime(startupTask)
            }

            startupTask.cancel()
            self.startupTask = nil
            startupModelFilename = nil
        }

        cachedRuntime = nil

        state = .starting("Initializing the in-process llama runtime.")
        diagnostics.lastError = nil
        diagnostics.lastLoadStatus = "Starting"
        diagnostics.modelFilePath = resolvedRuntime.modelFileURL.path
        let startupTask = Task { [core, configuration] in
            try await core.prepare(
                resolvedRuntime: resolvedRuntime,
                configuration: configuration
            )
        }
        self.startupTask = startupTask
        startupModelFilename = requestedModelFilename
        state = .loading("Loading \(resolvedRuntime.modelDisplayName) into memory.")

        return try await awaitPreparedRuntime(startupTask)
    }

    /// Resolves either the explicitly selected model or the default preferred model order.
    private func resolveSelectedRuntime() throws -> ResolvedLlamaRuntime {
        do {
            return try runtimeLocator.resolve(
                configuration: configuration,
                selectedModelFilename: selectedModelFilename
            )
        } catch {
            let runtimeError = LlamaRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    /// Validates the chosen filename against discovered bundled models and falls back to the first
    /// available option when the caller passes `nil` or a missing filename.
    private func normalizedModelFilename(_ filename: String?) -> String? {
        guard !availableModels.isEmpty else {
            return nil
        }

        guard let filename else {
            return availableModels.first?.filename
        }

        if availableModels.contains(where: { $0.filename == filename }) {
            return filename
        }

        return availableModels.first?.filename
    }

    /// Awaits the prepared runtime task and applies the published diagnostics on success.
    private func awaitPreparedRuntime(
        _ startupTask: Task<PreparedLlamaRuntime, Error>
    ) async throws -> PreparedLlamaRuntime {
        do {
            let preparedRuntime = try await startupTask.value
            cachedRuntime = preparedRuntime
            apply(preparedRuntime)
            self.startupTask = nil
            startupModelFilename = nil
            return preparedRuntime
        } catch is CancellationError {
            self.startupTask = nil
            startupModelFilename = nil
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            self.startupTask = nil
            startupModelFilename = nil
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(error.localizedDescription)
            throw error
        } catch {
            self.startupTask = nil
            startupModelFilename = nil
            let runtimeError = LlamaRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    /// Copies prepared runtime metadata into published diagnostics for the menu and startup UI.
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
