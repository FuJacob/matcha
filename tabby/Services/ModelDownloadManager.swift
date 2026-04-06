import AppKit
import Combine
import Foundation

/// One model's current install/download lifecycle state in local storage.
enum ModelDownloadState: Equatable {
    case idle
    case downloading
    case downloaded
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Not installed"
        case .downloading:
            return "Downloading"
        case .downloaded:
            return "Installed"
        case let .failed(message):
            return message
        }
    }
}

/// Downloads model files on demand into a user-writable runtime directory.
/// This decouples app shipping from model shipping so model updates do not require app updates.
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var modelStates: [String: ModelDownloadState] = [:]

    var onModelDirectoryChanged: (() -> Void)?

    private let runtimeDirectoryURL: URL
    private let runtimeSearchDirectories: [URL]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(runtimeDirectoryURL: URL? = nil) {
        let primaryDirectoryURL = runtimeDirectoryURL ?? BundledRuntimeLocator.userRuntimeDirectoryURL()
        self.runtimeDirectoryURL = primaryDirectoryURL

        var directories = [primaryDirectoryURL]
        for directoryURL in BundledRuntimeLocator.runtimeSearchDirectories() {
            let normalizedPath = directoryURL.standardizedFileURL.path
            if !directories.contains(where: { $0.standardizedFileURL.path == normalizedPath }) {
                directories.append(directoryURL)
            }
        }
        runtimeSearchDirectories = directories

        refreshModelStates()
    }

    var models: [DownloadableRuntimeModel] {
        RuntimeModelCatalog.downloadableModels
    }

    var modelsDirectoryPath: String {
        runtimeDirectoryURL.path
    }

    func state(for model: DownloadableRuntimeModel) -> ModelDownloadState {
        modelStates[model.filename] ?? .idle
    }

    func refreshModelStates() {
        for model in models {
            if downloadTasks[model.filename] != nil {
                modelStates[model.filename] = .downloading
            } else if isInstalled(model: model) {
                modelStates[model.filename] = .downloaded
            } else {
                modelStates[model.filename] = .idle
            }
        }
    }

    func download(_ model: DownloadableRuntimeModel) {
        guard downloadTasks[model.filename] == nil else {
            return
        }

        if isInstalled(model: model) {
            modelStates[model.filename] = .downloaded
            return
        }

        modelStates[model.filename] = .downloading
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.performDownload(model)
        }
        downloadTasks[model.filename] = task
    }

    func openModelsDirectory() {
        do {
            try ensureRuntimeDirectoryExists()
        } catch {
            return
        }

        NSWorkspace.shared.open(runtimeDirectoryURL)
    }

    private func performDownload(_ model: DownloadableRuntimeModel) async {
        defer {
            downloadTasks[model.filename] = nil
        }

        do {
            try ensureRuntimeDirectoryExists()
            let destinationURL = modelFileURL(filename: model.filename)

            let (temporaryURL, response) = try await URLSession.shared.download(from: model.downloadURL)
            try Task.checkCancellation()
            try validate(response: response)

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: temporaryURL, to: destinationURL)

            modelStates[model.filename] = .downloaded
            onModelDirectoryChanged?()
        } catch is CancellationError {
            if isInstalled(model: model) {
                modelStates[model.filename] = .downloaded
            } else {
                modelStates[model.filename] = .idle
            }
        } catch {
            modelStates[model.filename] = .failed(error.localizedDescription)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LlamaRuntimeError.unavailable("Model download failed with status code \(httpResponse.statusCode).")
        }
    }

    private func ensureRuntimeDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func modelFileURL(filename: String) -> URL {
        runtimeDirectoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func isInstalled(model: DownloadableRuntimeModel) -> Bool {
        model.allKnownFilenames.contains(where: isInstalled(filename:))
    }

    private func isInstalled(filename: String) -> Bool {
        runtimeSearchDirectories.contains { directoryURL in
            let fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
    }
}
