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

    static let `default` = LlamaRuntimeConfiguration(
        runtimeDirectoryPath: nil,
        preferredModelNames: [
            "qwen2-0_5b-instruct-q3_k_m.gguf",
            "Qwen3.5-0.8B-Q3_K_M.gguf",
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
