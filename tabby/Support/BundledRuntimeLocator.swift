import Foundation

/// File overview:
/// Resolves which GGUF assets Tabby should load by checking the app bundle first and the
/// development tree second. This keeps startup logic deterministic while still supporting local dev.
///
enum BundledRuntimeLocatorError: LocalizedError {
    case runtimeDirectoryMissing(String)
    case modelMissing(String)
    case namedModelMissing(String)

    var errorDescription: String? {
        switch self {
        case let .runtimeDirectoryMissing(path):
            return "Runtime directory is missing at \(path)."
        case let .modelMissing(path):
            return "No supported GGUF model was found at \(path)."
        case let .namedModelMissing(filename):
            return "The bundled model \(filename) was not found."
        }
    }
}

/// Resolves bundled GGUF assets from the app bundle first and the source tree second.
/// The folder name is still `LlamaRuntime` for now, but it is model storage only.
/// Tabby links llama.cpp in-process through `llama.swift`; it no longer launches a server.
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
        try resolve(configuration: configuration, selectedModelFilename: nil)
    }

    /// Resolves a specific model when selected explicitly, or the default preferred model order otherwise.
    func resolve(
        configuration: LlamaRuntimeConfiguration,
        selectedModelFilename: String?
    ) throws -> ResolvedLlamaRuntime {
        var lastError: Error?

        // We try candidates in order so production bundle paths win over local-dev fallbacks.
        for candidate in runtimeCandidates(for: configuration) {
            do {
                let modelOptions = try availableModels(
                    candidate: candidate,
                    preferredModelNames: configuration.preferredModelNames
                )

                let selectedOption: RuntimeModelOption
                if let selectedModelFilename {
                    guard let matchingOption = modelOptions.first(where: { $0.filename == selectedModelFilename }) else {
                        throw BundledRuntimeLocatorError.namedModelMissing(selectedModelFilename)
                    }
                    selectedOption = matchingOption
                } else if let firstOption = modelOptions.first {
                    selectedOption = firstOption
                } else {
                    throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
                }

                return resolvedRuntime(from: selectedOption, candidate: candidate)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? BundledRuntimeLocatorError.runtimeDirectoryMissing("No runtime candidates were available.")
    }

    /// Lists all GGUF models in deterministic display order for the highest-priority runtime candidate.
    func availableModels(configuration: LlamaRuntimeConfiguration) -> [RuntimeModelOption] {
        for candidate in runtimeCandidates(for: configuration) {
            if let modelOptions = try? availableModels(
                candidate: candidate,
                preferredModelNames: configuration.preferredModelNames
            ),
                !modelOptions.isEmpty
            {
                return modelOptions
            }
        }

        return []
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

    /// Enumerates and orders all GGUF models for one runtime candidate.
    private func availableModels(
        candidate: RuntimeCandidate,
        preferredModelNames: [String]
    ) throws -> [RuntimeModelOption] {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: candidate.runtimeDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BundledRuntimeLocatorError.runtimeDirectoryMissing(candidate.runtimeDirectoryURL.path)
        }

        var isModelDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: candidate.modelDirectoryURL.path, isDirectory: &isModelDirectory), isModelDirectory.boolValue else {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        let discoveredModelURLs = try fileManager.contentsOfDirectory(
            at: candidate.modelDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("gguf") == .orderedSame }

        guard !discoveredModelURLs.isEmpty else {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        let modelOptionsByFilename = Dictionary(uniqueKeysWithValues: discoveredModelURLs.map { modelURL in
            let option = RuntimeModelOption(
                filename: modelURL.lastPathComponent,
                url: modelURL
            )
            return (option.filename, option)
        })

        var orderedModels: [RuntimeModelOption] = []
        var seenFilenames = Set<String>()

        for preferredModelName in preferredModelNames {
            guard let modelOption = modelOptionsByFilename[preferredModelName],
                  seenFilenames.insert(preferredModelName).inserted
            else {
                continue
            }

            orderedModels.append(modelOption)
        }

        // Intentionally no alphabetical fallback here: the preferred list is treated as the
        // explicit allowlist for models that should be visible/selectable in-app.
        if orderedModels.isEmpty {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        return orderedModels
    }

    /// Builds the concrete runtime asset paths for one chosen model option.
    private func resolvedRuntime(
        from modelOption: RuntimeModelOption,
        candidate: RuntimeCandidate
    ) -> ResolvedLlamaRuntime {
        ResolvedLlamaRuntime(
            runtimeDirectoryURL: candidate.runtimeDirectoryURL,
            modelFileURL: modelOption.url,
            modelDisplayName: modelOption.displayName
        )
    }

    private static func developmentRuntimeDirectoryURL() -> URL {
        if let runtimeDirectoryPath = ProcessInfo.processInfo.environment["TABBY_RUNTIME_DIR"], !runtimeDirectoryPath.isEmpty {
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
