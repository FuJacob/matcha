import Combine
import Foundation

/// File overview:
/// Owns Tabby's developer diagnostics settings and event stream.
///
/// This object is deliberately global app state. The overlay flag and logging flag affect Focus,
/// OCR, prompt construction, runtime calls, and suggestion presentation, so they should not be
/// hidden inside one feature coordinator. Subsystems emit typed events here; the model decides
/// whether those events update the HUD, print colored console output, or both.
@MainActor
final class DeveloperDiagnosticsModel: ObservableObject {
    @Published private(set) var overlaysEnabled: Bool
    @Published private(set) var loggingEnabled: Bool
    @Published private(set) var latestEvent: DeveloperDiagnosticsEvent?
    @Published private(set) var recentEvents: [DeveloperDiagnosticsEvent] = []
    /// Session-scoped: OCR state for the current focused field. Does NOT reset on each keystroke.
    @Published private(set) var contextPipelineItem: DeveloperDiagnosticsPipelineItem
    /// Per-cycle: resets every time a new completion work unit begins.
    @Published private(set) var completionPipelineItems: [DeveloperDiagnosticsPipelineItem]

    private let userDefaults: UserDefaults
    private let consoleLogger = DeveloperDiagnosticsConsoleLogger()
    private var nextEventID: UInt64 = 0
    private var activeWorkID: UInt64?

    private static let overlaysEnabledDefaultsKey = "tabbyDeveloperDiagnosticsOverlaysEnabled"
    private static let loggingEnabledDefaultsKey = "tabbyDeveloperDiagnosticsLoggingEnabled"
    /// Stages that are worth surfacing in the "recent events" list in the HUD.
    /// AX observer events are excluded because they fire constantly and carry no action info.
    /// Focus/overlay/skipped events are excluded because they are not actionable to the developer.
    private static let recentEventStages: Set<DeveloperDiagnosticsStage> = [
        .ocr, .prompt, .llm, .normalize, .overlay, .acceptance, .runtime
    ]
    private static let maxRecentEvents = 5

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        overlaysEnabled = userDefaults.object(forKey: Self.overlaysEnabledDefaultsKey) as? Bool ?? false
        loggingEnabled = userDefaults.object(forKey: Self.loggingEnabledDefaultsKey) as? Bool ?? false
        contextPipelineItem = DeveloperDiagnosticsPipelineItem.idle(stage: .ocr)
        completionPipelineItems = DeveloperDiagnosticsStage.completionStages.map {
            DeveloperDiagnosticsPipelineItem.idle(stage: $0)
        }
    }

    /// Persists the overlay flag and hides the HUD immediately when disabled.
    func setOverlaysEnabled(_ enabled: Bool) {
        guard overlaysEnabled != enabled else {
            return
        }

        overlaysEnabled = enabled
        userDefaults.set(enabled, forKey: Self.overlaysEnabledDefaultsKey)
    }

    /// Persists the logging flag. Sensitive text blocks are only retained and printed while this
    /// flag is true, which keeps accidental prompt/OCR leakage out of normal development sessions.
    func setLoggingEnabled(_ enabled: Bool) {
        guard loggingEnabled != enabled else {
            return
        }

        loggingEnabled = enabled
        userDefaults.set(enabled, forKey: Self.loggingEnabledDefaultsKey)
    }

    /// Records one event in the shared diagnostics stream.
    ///
    /// `workID` acts like a frontend request ID: when it changes, the pipeline strip resets so an
    /// old LLM or overlay status cannot visually masquerade as part of the new request.
    func record(
        stage: DeveloperDiagnosticsStage,
        status: DeveloperDiagnosticsStatus,
        message: String,
        workID: UInt64? = nil,
        generation: UInt64? = nil,
        durationMilliseconds: Int? = nil,
        metadata: [String: String] = [:],
        textBlocks: [DeveloperDiagnosticsTextBlock] = []
    ) {
        resetPipelineIfNeeded(for: workID)

        nextEventID &+= 1
        let event = DeveloperDiagnosticsEvent(
            id: nextEventID,
            occurredAt: Date(),
            stage: stage,
            status: status,
            message: message,
            workID: workID,
            generation: generation,
            durationMilliseconds: durationMilliseconds,
            metadata: metadata,
            textBlocks: loggingEnabled ? textBlocks : []
        )

        latestEvent = event

        // Only log events from stages the developer actually cares about.
        // This keeps the recent-events list focused on the completion pipeline
        // rather than being swamped by constant AX observer notifications or
        // uninteresting overlay-show/hide bookkeeping.
        let isSignalBearingStage = Self.recentEventStages.contains(event.stage)
        let isSkippedOverlay = event.stage == .overlay && event.status == .skipped
        if isSignalBearingStage && !isSkippedOverlay {
            recentEvents = Array(([event] + recentEvents).prefix(Self.maxRecentEvents))
        }
        updatePipeline(from: event)

        if loggingEnabled {
            consoleLogger.log(event)
        }
    }

    /// Adapter for the existing suggestion coordinator stage names.
    ///
    /// Keeping this translation here lets the coordinator keep saying "generation is ready" while
    /// diagnostics can render that as concrete pipeline steps: LLM done, normalization done,
    /// overlay shown.
    func recordSuggestionStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64?,
        message: String,
        prompt: String?,
        rawOutput: String?,
        normalizedOutput: String?
    ) {
        switch stage {
        case "debouncing":
            record(
                stage: .focus,
                status: .running,
                message: message,
                workID: workID,
                generation: generation
            )

        case "generating":
            record(
                stage: .prompt,
                status: .succeeded,
                message: "Built LLM prompt.",
                workID: workID,
                generation: generation,
                metadata: prompt.map { ["chars": String($0.count)] } ?? [:],
                textBlocks: prompt.map {
                    [DeveloperDiagnosticsTextBlock(label: "raw LLM input", text: $0)]
                } ?? []
            )
            record(
                stage: .llm,
                status: .running,
                message: message,
                workID: workID,
                generation: generation
            )

        case "ready":
            record(
                stage: .llm,
                status: .succeeded,
                message: "Model returned a response.",
                workID: workID,
                generation: generation,
                metadata: rawOutput.map { ["rawChars": String($0.count)] } ?? [:],
                textBlocks: rawOutput.map {
                    [DeveloperDiagnosticsTextBlock(label: "raw model output", text: $0)]
                } ?? []
            )
            record(
                stage: .normalize,
                status: .succeeded,
                message: "Normalized model output.",
                workID: workID,
                generation: generation,
                metadata: normalizedOutput.map { ["finalChars": String($0.count)] } ?? [:],
                textBlocks: normalizedOutput.map {
                    [DeveloperDiagnosticsTextBlock(label: "final suggestion output", text: $0)]
                } ?? []
            )

        case "empty-result":
            record(
                stage: .normalize,
                status: .skipped,
                message: message,
                workID: workID,
                generation: generation,
                textBlocks: outputBlocks(rawOutput: rawOutput, normalizedOutput: normalizedOutput)
            )

        case "failed", "insert-failed":
            record(
                stage: stage == "insert-failed" ? .acceptance : .llm,
                status: .failed,
                message: message,
                workID: workID,
                generation: generation,
                textBlocks: outputBlocks(rawOutput: rawOutput, normalizedOutput: normalizedOutput)
            )

        case "stale-drop":
            record(
                stage: .llm,
                status: .stale,
                message: message,
                workID: workID,
                generation: generation,
                textBlocks: outputBlocks(rawOutput: rawOutput, normalizedOutput: normalizedOutput)
            )

        case "selected-text", "tab-passed-through":
            record(
                stage: .overlay,
                status: .skipped,
                message: message,
                workID: workID,
                generation: generation
            )

        case "tab-accepted-chunk",
            "tab-accepted-final-chunk",
            "typed-match-advanced",
            "typed-match-exhausted",
            "session-reconciled",
            "session-exhausted":
            record(
                stage: .acceptance,
                status: .succeeded,
                message: message,
                workID: workID,
                generation: generation,
                textBlocks: normalizedOutput.map {
                    [DeveloperDiagnosticsTextBlock(label: "accepted or remaining text", text: $0)]
                } ?? []
            )

        case "suppressed-synthetic-input":
            record(
                stage: .acceptance,
                status: .skipped,
                message: message,
                workID: workID,
                generation: generation
            )

        default:
            record(
                stage: .runtime,
                status: .running,
                message: message,
                workID: workID,
                generation: generation,
                textBlocks: outputBlocks(rawOutput: rawOutput, normalizedOutput: normalizedOutput)
            )
        }
    }

    /// Produces an escaped one-line preview suitable for menu/UI breadcrumbs.
    static func debugPreview(_ text: String) -> String {
        if text.isEmpty {
            return "<empty>"
        }

        let escaped = text.debugDescription
        guard escaped.count > 160 else {
            return escaped
        }

        let index = escaped.index(escaped.startIndex, offsetBy: 160)
        return "\(escaped[..<index])..."
    }

    private func resetPipelineIfNeeded(for workID: UInt64?) {
        guard let workID, activeWorkID != workID else {
            return
        }

        activeWorkID = workID
        // Only wipe the per-cycle completion stages. Context (OCR) is session-scoped
        // and should stay visible even as new completion cycles begin.
        completionPipelineItems = DeveloperDiagnosticsStage.completionStages.map {
            DeveloperDiagnosticsPipelineItem.idle(stage: $0)
        }
    }

    private func updatePipeline(from event: DeveloperDiagnosticsEvent) {
        if event.stage == .ocr {
            contextPipelineItem = contextPipelineItem.updated(from: event)
        } else if let index = completionPipelineItems.firstIndex(where: { $0.stage == event.stage }) {
            completionPipelineItems[index] = completionPipelineItems[index].updated(from: event)
        }
    }

    private func outputBlocks(
        rawOutput: String?,
        normalizedOutput: String?
    ) -> [DeveloperDiagnosticsTextBlock] {
        var blocks: [DeveloperDiagnosticsTextBlock] = []
        if let rawOutput {
            blocks.append(DeveloperDiagnosticsTextBlock(label: "raw model output", text: rawOutput))
        }
        if let normalizedOutput {
            blocks.append(DeveloperDiagnosticsTextBlock(label: "final suggestion output", text: normalizedOutput))
        }
        return blocks
    }
}

/// Responsible for the mechanics of colored console output.
///
/// The model decides whether logging is enabled; this type only formats one already-approved event.
private struct DeveloperDiagnosticsConsoleLogger {
    func log(_ event: DeveloperDiagnosticsEvent) {
        // Filter out highly noisy events from the console output.
        if event.stage == .axObserver { return }
        if event.stage == .overlay && event.status == .skipped { return }

        let color = ansiColor(for: event.stage, status: event.status)
        let reset = "\u{001B}[0m"
        let work = event.workID.map { " work=\($0)" } ?? ""
        let generation = event.generation.map { " generation=\($0)" } ?? ""
        let duration = event.durationMilliseconds.map { " elapsed_ms=\($0)" } ?? ""
        let metadata = event.metadata.isEmpty
            ? ""
            : " " + event.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")

        print(
            "\(color)[Tabby] \(event.stage.displayName) \(event.status.displayName)\(reset)"
                + "\(work)\(generation)\(duration)\(metadata) - \(event.message)"
        )

        for block in event.textBlocks where !block.text.isEmpty {
            print(
                """
                \(color)----- BEGIN \(block.label.uppercased()) -----\(reset)
                \(block.text)
                \(color)----- END \(block.label.uppercased()) -----\(reset)
                """
            )
        }
    }

    private func ansiColor(
        for stage: DeveloperDiagnosticsStage,
        status: DeveloperDiagnosticsStatus
    ) -> String {
        if status == .failed {
            return "\u{001B}[31m"
        }
        if status == .stale || status == .skipped || status == .cancelled {
            return "\u{001B}[33m"
        }

        switch stage {
        case .focus:
            return "\u{001B}[36m"
        case .axObserver:
            return "\u{001B}[96m"
        case .ocr:
            return "\u{001B}[35m"
        case .prompt:
            return "\u{001B}[34m"
        case .llm:
            return "\u{001B}[32m"
        case .normalize:
            return "\u{001B}[92m"
        case .overlay:
            return "\u{001B}[95m"
        case .acceptance:
            return "\u{001B}[94m"
        case .runtime:
            return "\u{001B}[90m"
        }
    }
}
