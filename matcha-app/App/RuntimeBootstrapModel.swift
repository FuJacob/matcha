import Combine
import Foundation

/// Keeps process lifecycle separate from SwiftUI view lifecycle.
@MainActor
final class RuntimeBootstrapModel: ObservableObject {
    /// `@Published` automatically notifies SwiftUI views when these values change.
    @Published private(set) var state: RuntimeBootstrapState
    @Published private(set) var diagnostics: LlamaRuntimeDiagnostics

    private let runtimeManager: LlamaRuntimeManager
    private var cancellables = Set<AnyCancellable>()
    private var startupTask: Task<Void, Never>?

    init(runtimeManager: LlamaRuntimeManager) {
        self.runtimeManager = runtimeManager
        state = runtimeManager.state
        diagnostics = runtimeManager.diagnostics

        // `sink` subscribes to publisher updates; storing cancellables keeps subscriptions alive.
        runtimeManager.$state
            .sink { [weak self] state in
                self?.state = state
            }
            .store(in: &cancellables)

        runtimeManager.$diagnostics
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
                try await self.runtimeManager.prepare()
            } catch {
                print("Runtime startup failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        runtimeManager.stop()
    }
}
