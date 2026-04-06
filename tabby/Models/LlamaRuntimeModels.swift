import Foundation

/// File overview:
/// Shared value types for runtime bootstrap, model selection, diagnostics, and runtime errors.
/// These types keep runtime state serializable, testable, and separate from the service layer.
///
/// Human-readable lifecycle states surfaced to the UI during runtime bootstrap.
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

/// One bundled GGUF model option that can be displayed in the menu and loaded at runtime.
/// Filenames remain user-visible in v1 so selection maps directly to the actual disk asset.
struct RuntimeModelOption: Equatable, Hashable, Sendable, Identifiable {
    let filename: String
    let url: URL

    var id: String { filename }
    var displayName: String { RuntimeModelCatalog.displayName(for: filename) }
}

/// Downloadable model metadata used by onboarding and menu-based model installation.
/// Keeping this as app-level data lets us update app code and model artifacts independently.
struct DownloadableRuntimeModel: Equatable, Hashable, Sendable, Identifiable {
    let filename: String
    let displayName: String
    let downloadURL: URL
    let alternateFilenames: [String]

    var id: String { filename }

    var allKnownFilenames: [String] {
        [filename] + alternateFilenames
    }

    init(
        filename: String,
        displayName: String,
        downloadURL: URL,
        alternateFilenames: [String] = []
    ) {
        self.filename = filename
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.alternateFilenames = alternateFilenames
    }
}

enum RuntimeModelCatalog {
    static func displayName(for filename: String) -> String {
        switch filename {
        case "Qwen3.5-0.8B-Q3_K_M.gguf":
            return "Qwen 0.8B (fast)"
        case "Qwen3.5-2B-Q4_K_M.gguf":
            return "Qwen 2B (balanced)"
        case "Qwen3.5-9B-Q4_K_M.gguf":
            return "Qwen 9B (quality)"
        case "ministral-3-8b-base-2512-q4_k_m.gguf":
            return "Ministral 8B (quality)"
        case "Phi-3-mini-128k-instruct.Q4_K_M.gguf":
            return "Phi-3 Mini (balanced)"
        case "nb-llama-3.2-3b_1200-q4_k_m.gguf", "Llama-3.2-3B.Q4_K_M.gguf":
            return "Llama 3.2 3B (balanced)"
        case "google_gemma-4-E2B-it-Q4_K_M.gguf":
            return "Gemma 4 2B (fast)"
        case "gemma-3n-E4B-it-Q4_K_M.gguf":
            return "Gemma 3n 4B (balanced, recommended)"
        default:
            return filename
        }
    }

    /// Canonical downloadable model list shown in Welcome and menu UI.
    static let downloadableModels: [DownloadableRuntimeModel] = [
        DownloadableRuntimeModel(
            filename: "nb-llama-3.2-3b_1200-q4_k_m.gguf",
            displayName: displayName(for: "nb-llama-3.2-3b_1200-q4_k_m.gguf"),
            downloadURL: URL(string: "https://huggingface.co/NbAiLab/nb-llama-3.2-3B-Q4_K_M-GGUF/resolve/main/nb-llama-3.2-3b_1200-q4_k_m.gguf?download=true")!,
            alternateFilenames: ["Llama-3.2-3B.Q4_K_M.gguf"]
        ),
        DownloadableRuntimeModel(
            filename: "ministral-3-8b-base-2512-q4_k_m.gguf",
            displayName: displayName(for: "ministral-3-8b-base-2512-q4_k_m.gguf"),
            downloadURL: URL(string: "https://huggingface.co/srhm-ca/Ministral-3-8B-Base-2512-Q4_K_M-GGUF/resolve/main/ministral-3-8b-base-2512-q4_k_m.gguf?download=true")!
        ),
        DownloadableRuntimeModel(
            filename: "Phi-3-mini-128k-instruct.Q4_K_M.gguf",
            displayName: displayName(for: "Phi-3-mini-128k-instruct.Q4_K_M.gguf"),
            downloadURL: URL(string: "https://huggingface.co/QuantFactory/Phi-3-mini-128k-instruct-GGUF/resolve/main/Phi-3-mini-128k-instruct.Q4_K_M.gguf?download=true")!
        ),
        DownloadableRuntimeModel(
            filename: "Qwen3.5-0.8B-Q3_K_M.gguf",
            displayName: displayName(for: "Qwen3.5-0.8B-Q3_K_M.gguf"),
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q3_K_M.gguf?download=true")!
        ),
        DownloadableRuntimeModel(
            filename: "Qwen3.5-2B-Q4_K_M.gguf",
            displayName: displayName(for: "Qwen3.5-2B-Q4_K_M.gguf"),
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true")!
        ),
        DownloadableRuntimeModel(
            filename: "Qwen3.5-9B-Q4_K_M.gguf",
            displayName: displayName(for: "Qwen3.5-9B-Q4_K_M.gguf"),
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true")!
        ),
        DownloadableRuntimeModel(
            filename: "google_gemma-4-E2B-it-Q4_K_M.gguf",
            displayName: displayName(for: "google_gemma-4-E2B-it-Q4_K_M.gguf"),
            downloadURL: URL(string: "https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF/resolve/main/google_gemma-4-E2B-it-Q4_K_M.gguf?download=true")!
        ),
        DownloadableRuntimeModel(
            filename: "gemma-3n-E4B-it-Q4_K_M.gguf",
            displayName: displayName(for: "gemma-3n-E4B-it-Q4_K_M.gguf"),
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-Q4_K_M.gguf?download=true")!
        ),
    ]
}

/// Startup configuration that controls which GGUF model to load and how large the runtime should be.
struct LlamaRuntimeConfiguration: Equatable, Sendable {
    let runtimeDirectoryPath: String?
    let preferredModelNames: [String]
    let contextWindowTokens: Int32
    let batchSize: Int32
    let gpuLayerCount: Int32

    /// Order matters here: the locator picks the first GGUF that exists.
    /// This list defines priority for known models; user-added GGUF files are still discoverable.
    static let `default` = LlamaRuntimeConfiguration(
        runtimeDirectoryPath: nil,
        preferredModelNames: [
            "gemma-3n-E4B-it-Q4_K_M.gguf",
            "Qwen3.5-9B-Q4_K_M.gguf",
            "ministral-3-8b-base-2512-q4_k_m.gguf",
            "Qwen3.5-2B-Q4_K_M.gguf",
            "google_gemma-4-E2B-it-Q4_K_M.gguf",
            "Qwen3.5-0.8B-Q3_K_M.gguf",
            "Phi-3-mini-128k-instruct.Q4_K_M.gguf",
            "nb-llama-3.2-3b_1200-q4_k_m.gguf",
            "Llama-3.2-3B.Q4_K_M.gguf",
        ],
        contextWindowTokens: 2048,
        batchSize: 512,
        gpuLayerCount: -1
    )
}

/// The concrete runtime assets selected during bootstrap after checking available model files.
struct ResolvedLlamaRuntime: Equatable, Sendable {
    let runtimeDirectoryURL: URL
    let modelFileURL: URL
    let modelDisplayName: String
}

/// Operator-facing runtime metadata used by the menu and startup diagnostics.
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

/// Runtime failures surfaced before or during in-process generation.
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
