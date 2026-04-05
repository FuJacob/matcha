import Foundation

enum RuntimeBootstrapState: Equatable {
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

struct LlamaRuntimeConfiguration: Equatable {
    let runtimeDirectoryPath: String?
    let preferredModelNames: [String]
    let preferredPort: Int?

    /// Order matters here: the locator picks the first GGUF that exists.
    /// Keeping fallbacks behind the preferred model makes the startup path deterministic.
    static let `default` = LlamaRuntimeConfiguration(
        runtimeDirectoryPath: nil,
        preferredModelNames: [
            // Prefer the larger Qwen 3.5 model first; later entries are compatibility fallbacks.
            "Qwen3.5-0.8B-Q3_K_M.gguf",
            "qwen2-0_5b-instruct-q2_k.gguf",
            "qwen2-0_5b-instruct-q3_k_m.gguf",
        ],
        preferredPort: nil
    )
}

struct ResolvedLlamaRuntime: Equatable {
    let runtimeDirectoryURL: URL
    let serverBinaryURL: URL
    let modelFileURL: URL
    let modelDisplayName: String
}

struct LlamaRuntimeDiagnostics: Equatable {
    var runtimeDirectoryPath: String?
    var serverBinaryPath: String?
    var modelFilePath: String?
    var serverPort: Int?
    var lastHealthStatus: String?
    var lastError: String?
    var recentServerLog: String?
}

enum LlamaServerError: LocalizedError {
    case unavailable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return message
        case .cancelled:
            return "Runtime startup was cancelled."
        }
    }
}
