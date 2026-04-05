import Combine
import Darwin
import Foundation

/// Owns exactly one `llama-server` child process for this app instance.
@MainActor
final class LlamaServerManager: ObservableObject {
    /// The view observes these for operator-facing runtime diagnostics.
    @Published private(set) var state: RuntimeBootstrapState = .idle
    @Published private(set) var diagnostics = LlamaRuntimeDiagnostics()

    private let configuration: LlamaRuntimeConfiguration
    private let runtimeLocator: BundledRuntimeLocator
    private let session: URLSession

    private var process: Process?
    private var startupTask: Task<URL, Error>?
    private var outputPipe: Pipe?
    private var recentLogBuffer = ""
    private var stopRequested = false

    private(set) var baseURL: URL?

    /// Convenience init avoids actor-isolated default arguments in a nonisolated call site.
    convenience init() {
        self.init(
            configuration: .default,
            runtimeLocator: BundledRuntimeLocator()
        )
    }

    init(
        configuration: LlamaRuntimeConfiguration,
        runtimeLocator: BundledRuntimeLocator
    ) {
        self.configuration = configuration
        self.runtimeLocator = runtimeLocator

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 4
        sessionConfiguration.timeoutIntervalForResource = 4
        sessionConfiguration.waitsForConnectivity = false
        session = URLSession(configuration: sessionConfiguration)
    }

    /// Returns the existing startup task when launch is already in progress to avoid duplicate child processes.
    /// This is the key "single supervisor -> single server" invariant.
    func start() async throws -> URL {
        if case .ready = state, let baseURL {
            return baseURL
        }

        if let startupTask {
            return try await startupTask.value
        }

        let task = Task<URL, Error> { @MainActor [weak self] in
            guard let self else {
                throw LlamaServerError.cancelled
            }

            return try await self.launchServer()
        }

        startupTask = task

        do {
            let baseURL = try await task.value
            startupTask = nil
            return baseURL
        } catch {
            startupTask = nil
            throw error
        }
    }

    /// Explicit stop keeps control of process ownership and prevents orphan servers.
    func stopSynchronously() {
        tearDownRuntime(cancelStartupTask: true, updateStateToIdle: true)
    }

    private func launchServer() async throws -> URL {
        // Do not cancel `startupTask` here because this code is running inside that task.
        // We only want to clear previously owned runtime state before the new launch begins.
        tearDownRuntime(cancelStartupTask: false, updateStateToIdle: false)
        stopRequested = false

        let runtime = try runtimeLocator.resolve(configuration: configuration)
        let port = try configuration.preferredPort ?? Self.reserveOpenPort()
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!

        diagnostics.runtimeDirectoryPath = runtime.runtimeDirectoryURL.path
        diagnostics.serverBinaryPath = runtime.serverBinaryURL.path
        diagnostics.modelFilePath = runtime.modelFileURL.path
        diagnostics.serverPort = port
        diagnostics.lastError = nil
        diagnostics.lastHealthStatus = "Starting"

        let process = Process()
        process.executableURL = runtime.serverBinaryURL
        process.currentDirectoryURL = runtime.runtimeDirectoryURL
        process.arguments = [
            "-m", runtime.modelFileURL.path,
            "--slots",
            "--parallel", "1",
            "--host", "127.0.0.1",
            "--port", "\(port)",
        ]

        configureProcessOutputCapture(for: process)
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleTermination(of: terminatedProcess)
            }
        }

        state = .starting("Launching llama-server with \(runtime.modelDisplayName).")

        do {
            try process.run()
        } catch {
            let message = "Failed to launch llama-server: \(error.localizedDescription)"
            diagnostics.lastError = message
            state = .failed(message)
            throw LlamaServerError.unavailable(message)
        }

        self.process = process

        do {
            try await pollUntilReady(baseURL: baseURL, modelName: runtime.modelDisplayName, launchedProcess: process)
        } catch {
            tearDownRuntime(cancelStartupTask: false, updateStateToIdle: true)

            if error is CancellationError {
                throw LlamaServerError.cancelled
            }

            diagnostics.lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
            throw error
        }

        self.baseURL = baseURL
        diagnostics.lastHealthStatus = "HTTP 200"
        state = .ready("llama-server is healthy at \(baseURL.absoluteString)")
        return baseURL
    }

    /// This mirrors the old working runtime design: teardown behavior depends on call site.
    /// A user-initiated stop should cancel startup, but a pre-launch reset must not.
    private func tearDownRuntime(cancelStartupTask: Bool, updateStateToIdle: Bool) {
        stopRequested = true

        if cancelStartupTask {
            startupTask?.cancel()
            startupTask = nil
        }

        baseURL = nil
        diagnostics.serverPort = nil

        if let process {
            process.terminationHandler = nil
            self.process = nil
            if process.isRunning {
                process.terminate()
            }
        }

        teardownProcessOutputCapture()

        if updateStateToIdle {
            state = .idle
        }
    }

    private func pollUntilReady(
        baseURL: URL,
        modelName: String,
        launchedProcess: Process
    ) async throws {
        // We mark ready only after /health returns 200, not when the process merely starts.
        let deadline = Date().addingTimeInterval(90)

        while Date() < deadline {
            try Task.checkCancellation()
            try throwIfStartupProcessDied(launchedProcess)

            do {
                let healthURL = baseURL.appending(path: "health")
                let (data, response) = try await session.data(from: healthURL)
                guard let httpResponse = response as? HTTPURLResponse else {
                    diagnostics.lastHealthStatus = "Waiting for valid /health response"
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                switch httpResponse.statusCode {
                case 200:
                    diagnostics.lastHealthStatus = "HTTP 200"
                    return
                case 503:
                    diagnostics.lastHealthStatus = "HTTP 503"
                    state = .loading("Loading model \(modelName)")
                default:
                    diagnostics.lastHealthStatus = "HTTP \(httpResponse.statusCode)"
                    let body = String(decoding: data, as: UTF8.self)
                    diagnostics.lastError = body.isEmpty ? "Health check returned HTTP \(httpResponse.statusCode)." : body
                }
            } catch {
                try throwIfStartupProcessDied(launchedProcess)
                diagnostics.lastHealthStatus = "Waiting for listener"
            }

            try await Task.sleep(nanoseconds: 350_000_000)
        }

        throw LlamaServerError.unavailable("llama-server did not become healthy within 90 seconds.")
    }

    private func throwIfStartupProcessDied(_ launchedProcess: Process) throws {
        if stopRequested {
            throw LlamaServerError.cancelled
        }

        guard process === launchedProcess, launchedProcess.isRunning else {
            throw LlamaServerError.unavailable("llama-server exited before /health returned 200.")
        }
    }

    private func handleTermination(of terminatedProcess: Process) {
        self.process = nil
        baseURL = nil

        guard !stopRequested else {
            diagnostics.lastHealthStatus = "Stopped"
            return
        }

        let message: String
        switch terminatedProcess.terminationReason {
        case .exit:
            message = "llama-server exited with code \(terminatedProcess.terminationStatus)."
        case .uncaughtSignal:
            message = "llama-server was killed by signal \(terminatedProcess.terminationStatus)."
        @unknown default:
            message = "llama-server terminated for an unknown reason."
        }

        diagnostics.lastHealthStatus = "Terminated"
        diagnostics.lastError = message
        state = .failed(message)
    }

    private func configureProcessOutputCapture(for process: Process) {
        teardownProcessOutputCapture()

        let pipe = Pipe()
        outputPipe = pipe
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendLogChunk(chunk)
            }
        }
    }

    private func teardownProcessOutputCapture() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
    }

    private func appendLogChunk(_ chunk: String) {
        recentLogBuffer.append(chunk)

        if recentLogBuffer.count > 12_000 {
            recentLogBuffer = String(recentLogBuffer.suffix(8_000))
        }

        diagnostics.recentServerLog = recentLogBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func reserveOpenPort() throws -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw LlamaServerError.unavailable("Unable to reserve a local port for llama-server.")
        }

        defer {
            close(socketDescriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(socketDescriptor, pointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard bindResult == 0 else {
            throw LlamaServerError.unavailable("Unable to bind a local port for llama-server.")
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(socketDescriptor, pointer, &addressLength)
            }
        }

        guard nameResult == 0 else {
            throw LlamaServerError.unavailable("Unable to read the reserved llama-server port.")
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }
}
