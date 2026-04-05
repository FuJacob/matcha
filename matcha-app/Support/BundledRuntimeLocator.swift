import Foundation

/// File overview:
/// Resolves which GGUF assets Matcha should load by checking the app bundle first and the
/// development tree second. This keeps startup logic deterministic while still supporting local dev.
///
enum BundledRuntimeLocatorError: LocalizedError {
    case runtimeDirectoryMissing(String)
    case modelMissing(String)

    var errorDescription: String? {
        switch self {
        case let .runtimeDirectoryMissing(path):
            return "Runtime directory is missing at \(path)."
        case let .modelMissing(path):
            return "No supported GGUF model was found at \(path)."
        }
    }
}

/// Resolves bundled GGUF assets from the app bundle first and the source tree second.
/// The folder name is still `LlamaRuntime` for now, but it is model storage only.
/// Matcha links llama.cpp in-process through `llama.swift`; it no longer launches a server.
struct BundledRuntimeLocator {
    private struct RuntimeCandidate {
        let runtimeDirectoryURL: URL
        let modelDirectoryURL: URL
    }

    static let runtimeFolderName = "LlamaRuntime"

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Finds the first preferred bundled model that exists and returns the fully resolved runtime asset paths.
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

    /// Enumerates possible runtime directories in bundle-first, development-second order.
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

    /// Verifies that a candidate directory contains one of the preferred model files.
    private func validate(
        candidate: RuntimeCandidate,
        preferredModelNames: [String]
    ) throws -> ResolvedLlamaRuntime {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: candidate.runtimeDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BundledRuntimeLocatorError.runtimeDirectoryMissing(candidate.runtimeDirectoryURL.path)
        }

        guard let modelFileURL = preferredModelNames
            .map({ candidate.modelDirectoryURL.appendingPathComponent($0) })
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        else {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        return ResolvedLlamaRuntime(
            runtimeDirectoryURL: candidate.runtimeDirectoryURL,
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
