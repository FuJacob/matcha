import Foundation

enum BundledRuntimeLocatorError: LocalizedError {
    case runtimeDirectoryMissing(String)
    case serverBinaryMissing(String)
    case serverBinaryNotExecutable(String)
    case modelMissing(String)
    case dependencyMissing(String)

    var errorDescription: String? {
        switch self {
        case let .runtimeDirectoryMissing(path):
            return "Runtime directory is missing at \(path)."
        case let .serverBinaryMissing(path):
            return "llama-server is missing at \(path)."
        case let .serverBinaryNotExecutable(path):
            return "llama-server is not executable at \(path)."
        case let .modelMissing(path):
            return "No supported GGUF model was found at \(path)."
        case let .dependencyMissing(path):
            return "Required llama.cpp dependency is missing at \(path)."
        }
    }
}

/// Resolves runtime assets from bundle layout first and a source-tree fallback second.
/// Keeping `LlamaRuntime` outside the Xcode target folder prevents the app binary from
/// accidentally linking against llama.cpp dylibs. The app should launch `llama-server`,
/// not become a direct consumer of ggml/llama dynamic libraries.
struct BundledRuntimeLocator {
    private struct RuntimeCandidate {
        let runtimeDirectoryURL: URL
        let modelDirectoryURL: URL
    }

    static let runtimeFolderName = "LlamaRuntime"
    static let bundledServerName = "llama-server"
    static let requiredLibraryNames = [
        "libggml-base.0.dylib",
        "libggml-blas.0.dylib",
        "libggml-cpu.0.dylib",
        "libggml-metal.0.dylib",
        "libggml-rpc.0.dylib",
        "libggml.0.dylib",
        "libllama.0.dylib",
        "libmtmd.0.dylib",
    ]

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func resolve(configuration: LlamaRuntimeConfiguration) throws -> ResolvedLlamaRuntime {
        var lastError: Error?

        // We try candidates in order so production bundle paths win over local-dev fallbacks.
        for candidate in runtimeCandidates(for: configuration) {
            do {
                return try validate(candidate: candidate, preferredModelNames: configuration.preferredModelNames)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? BundledRuntimeLocatorError.runtimeDirectoryMissing("No runtime candidates were available.")
    }

    private func runtimeCandidates(for configuration: LlamaRuntimeConfiguration) -> [RuntimeCandidate] {
        if let runtimeDirectoryPath = configuration.runtimeDirectoryPath, !runtimeDirectoryPath.isEmpty {
            let runtimeDirectoryURL = URL(fileURLWithPath: runtimeDirectoryPath, isDirectory: true)
            return [
                RuntimeCandidate(
                    runtimeDirectoryURL: runtimeDirectoryURL,
                    modelDirectoryURL: runtimeDirectoryURL
                )
            ]
        }

        var candidates: [RuntimeCandidate] = []

        if
            let executableDirectoryURL = bundle.executableURL?.deletingLastPathComponent(),
            let resourceDirectoryURL = bundle.resourceURL
        {
            candidates.append(
                RuntimeCandidate(
                    runtimeDirectoryURL: executableDirectoryURL.appendingPathComponent(Self.runtimeFolderName, isDirectory: true),
                    modelDirectoryURL: resourceDirectoryURL.appendingPathComponent(Self.runtimeFolderName, isDirectory: true)
                )
            )
        }

        let developmentRuntimeDirectoryURL = Self.developmentRuntimeDirectoryURL()
        candidates.append(
            RuntimeCandidate(
                runtimeDirectoryURL: developmentRuntimeDirectoryURL,
                modelDirectoryURL: developmentRuntimeDirectoryURL
            )
        )

        return candidates
    }

    private func validate(
        candidate: RuntimeCandidate,
        preferredModelNames: [String]
    ) throws -> ResolvedLlamaRuntime {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: candidate.runtimeDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BundledRuntimeLocatorError.runtimeDirectoryMissing(candidate.runtimeDirectoryURL.path)
        }

        let serverBinaryURL = candidate.runtimeDirectoryURL.appendingPathComponent(Self.bundledServerName)
        guard fileManager.fileExists(atPath: serverBinaryURL.path) else {
            throw BundledRuntimeLocatorError.serverBinaryMissing(serverBinaryURL.path)
        }

        guard fileManager.isExecutableFile(atPath: serverBinaryURL.path) else {
            throw BundledRuntimeLocatorError.serverBinaryNotExecutable(serverBinaryURL.path)
        }

        for libraryName in Self.requiredLibraryNames {
            let libraryURL = candidate.runtimeDirectoryURL.appendingPathComponent(libraryName)
            guard fileManager.fileExists(atPath: libraryURL.path) else {
                throw BundledRuntimeLocatorError.dependencyMissing(libraryURL.path)
            }
        }

        guard let modelFileURL = preferredModelNames
            .map({ candidate.modelDirectoryURL.appendingPathComponent($0) })
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        else {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        return ResolvedLlamaRuntime(
            runtimeDirectoryURL: candidate.runtimeDirectoryURL,
            serverBinaryURL: serverBinaryURL,
            modelFileURL: modelFileURL,
            modelDisplayName: modelFileURL.lastPathComponent
        )
    }

    private static func developmentRuntimeDirectoryURL() -> URL {
        if let runtimeDirectoryPath = ProcessInfo.processInfo.environment["MATCHA_RUNTIME_DIR"], !runtimeDirectoryPath.isEmpty {
            return URL(fileURLWithPath: runtimeDirectoryPath, isDirectory: true)
        }

        // `#filePath` is compile-time Swift syntax that expands to this source file's absolute path.
        // We use it only for local development fallback path resolution.
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        return sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(Self.runtimeFolderName, isDirectory: true)
    }
}
