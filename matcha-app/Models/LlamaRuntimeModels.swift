import Foundation

enum RuntimeBootstrapState: Equatable, Sendable {
    case idle
    case starting(String)
    case loading(String)
    case ready(String)
    case failed(String)

    var summary: String {
        switch self {
        case .idle:
            return "Idle"
        case let .starting(detail),
            let .loading(detail),
            let .ready(detail),
            let .failed(detail):
            return detail
        }
    }
}

struct LlamaRuntimeConfiguration: Equatable, Sendable {
    let runtimeDirectoryPath: String?
    let preferredModelNames: [String]
    let contextWindowTokens: Int32
    let batchSize: Int32
    let gpuLayerCount: Int32

    /// Order matters here: the locator picks the first GGUF that exists.
    /// Keeping fallbacks behind the preferred model makes the startup path deterministic.
    static let `default` = LlamaRuntimeConfiguration(
        runtimeDirectoryPath: nil,
        preferredModelNames: [
            "Qwen3.5-2B-Q4_K_M.gguf",
            "Qwen3.5-0.8B-Q3_K_M.gguf",
            "qwen2-0_5b-instruct-q2_k.gguf",
            "qwen2-0_5b-instruct-q3_k_m.gguf",
        ],
        contextWindowTokens: 2048,
        batchSize: 512,
        gpuLayerCount: -1
    )
}

struct ResolvedLlamaRuntime: Equatable, Sendable {
    let runtimeDirectoryURL: URL
    let modelFileURL: URL
    let modelDisplayName: String
}

struct LlamaRuntimeDiagnostics: Equatable, Sendable {
    var runtimeDirectoryPath: String?
    var modelFilePath: String?
    var backendName: String?
    var contextWindowTokens: Int?
    var batchSize: Int?
    var threadCount: Int?
    var gpuLayerCount: Int?
    var lastLoadStatus: String?
    var lastError: String?
}

enum LlamaRuntimeError: LocalizedError {
    case unavailable(String)
    case cancelled
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .generationFailed(message):
            return message
        case .cancelled:
            return "Runtime work was cancelled."
        }
    }
}
