import Combine
import Foundation

/// Keeps process lifecycle separate from SwiftUI view lifecycle.
@MainActor
final class RuntimeBootstrapModel: ObservableObject {
    /// `@Published` automatically notifies SwiftUI views when these values change.
    @Published private(set) var state: RuntimeBootstrapState
    @Published private(set) var diagnostics: LlamaRuntimeDiagnostics

    private let serverManager: LlamaServerManager
    private var cancellables = Set<AnyCancellable>()
    private var startupTask: Task<Void, Never>?

    /// Convenience init avoids actor-isolated default arguments in a nonisolated call site.
    convenience init() {
        self.init(serverManager: LlamaServerManager())
    }

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager
        state = serverManager.state
        diagnostics = serverManager.diagnostics

        // `sink` subscribes to publisher updates; storing cancellables keeps subscriptions alive.
        serverManager.$state
            .sink { [weak self] state in
                self?.state = state
            }
            .store(in: &cancellables)

        serverManager.$diagnostics
            .sink { [weak self] diagnostics in
                self?.diagnostics = diagnostics
            }
            .store(in: &cancellables)
    }

    /// Idempotent bootstrap ensures only one launch flow is active.
    func startIfNeeded() {
        guard startupTask == nil else {
            return
        }

        // A Task lets us call async startup from non-async app lifecycle methods.
        startupTask = Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.startupTask = nil
            }

            do {
                _ = try await self.serverManager.start()
            } catch {
                print("Runtime startup failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        serverManager.stopSynchronously()
    }

    var menuBarIconName: String {
        switch state {
        case .idle:
            return "leaf"
        case .starting, .loading:
            return "cpu"
        case .ready:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}
