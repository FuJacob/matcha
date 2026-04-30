import Foundation

/// File overview:
/// Pure value types for Tabby's developer diagnostics surface.
///
/// These models intentionally contain no AppKit, SwiftUI, Accessibility, or console-printing code.
/// The same event stream can therefore drive two outputs safely:
/// 1. a compact on-screen debug HUD
/// 2. colored console logs
///
/// This mirrors a frontend pattern where app logic emits typed telemetry events and different
/// subscribers render them as UI, logs, or traces.

/// The coarse pipeline stage a diagnostic event belongs to.
enum DeveloperDiagnosticsStage: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case focus
    case axObserver
    case ocr
    case prompt
    case llm
    case normalize
    case overlay
    case acceptance
    case runtime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .focus:
            return "Focus"
        case .axObserver:
            return "AX"
        case .ocr:
            // Called "Context" in the UI because it represents visual context injected
            // into the prompt, not a raw OCR pipeline detail.
            return "Context"
        case .prompt:
            // "Inject" makes clear this is where prefix + context enters the LLM prompt.
            return "Inject"
        case .llm:
            return "Model"
        case .normalize:
            // "Filter" makes clear this is post-processing raw model output into the
            // final suggestion string, not an injection step.
            return "Filter"
        case .overlay:
            return "Show"
        case .acceptance:
            return "Accept"
        case .runtime:
            return "Runtime"
        }
    }

    /// OCR/context runs once per focused field session, not on every keystroke.
    /// Keeping it separate prevents it being wiped when the completion pipeline resets.
    static let sessionStages: [DeveloperDiagnosticsStage] = [.ocr]

    /// These stages reset on every new completion work cycle.
    static let completionStages: [DeveloperDiagnosticsStage] = [
        .prompt, .llm, .normalize, .overlay, .acceptance,
    ]

    /// All pipeline-strip stages (session + completion). AX observer is shown separately.
    static let pipelineStages: [DeveloperDiagnosticsStage] = sessionStages + completionStages
}

/// The current state of one diagnostic stage.
enum DeveloperDiagnosticsStatus: String, Equatable, Sendable {
    case idle
    case running
    case succeeded
    case skipped
    case failed
    case cancelled
    case stale

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .succeeded:
            return "Done"
        case .skipped:
            return "Skipped"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .stale:
            return "Stale"
        }
    }
}

/// A sensitive text payload attached to a diagnostic event.
///
/// The overlay never renders these blocks. They exist so console logging can show exact raw prompt,
/// OCR, and model-output payloads when the developer explicitly enables logging.
struct DeveloperDiagnosticsTextBlock: Equatable, Sendable {
    let label: String
    let text: String
}

/// One typed event in Tabby's developer diagnostics stream.
struct DeveloperDiagnosticsEvent: Identifiable, Equatable, Sendable {
    let id: UInt64
    let occurredAt: Date
    let stage: DeveloperDiagnosticsStage
    let status: DeveloperDiagnosticsStatus
    let message: String
    let workID: UInt64?
    let generation: UInt64?
    let durationMilliseconds: Int?
    let metadata: [String: String]
    let textBlocks: [DeveloperDiagnosticsTextBlock]
}

/// The HUD-friendly state for a single pipeline stage.
struct DeveloperDiagnosticsPipelineItem: Identifiable, Equatable, Sendable {
    let stage: DeveloperDiagnosticsStage
    let status: DeveloperDiagnosticsStatus
    let message: String?
    let updatedAt: Date?
    let durationMilliseconds: Int?

    var id: DeveloperDiagnosticsStage { stage }

    static func idle(stage: DeveloperDiagnosticsStage) -> DeveloperDiagnosticsPipelineItem {
        DeveloperDiagnosticsPipelineItem(
            stage: stage,
            status: .idle,
            message: nil,
            updatedAt: nil,
            durationMilliseconds: nil
        )
    }

    func updated(from event: DeveloperDiagnosticsEvent) -> DeveloperDiagnosticsPipelineItem {
        DeveloperDiagnosticsPipelineItem(
            stage: stage,
            status: event.status,
            message: event.message,
            updatedAt: event.occurredAt,
            durationMilliseconds: event.durationMilliseconds
        )
    }
}

/// One compact key/value row shown in the developer HUD.
struct DeveloperDiagnosticsField: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String { "\(label)::\(value)" }
}

/// Complete render payload for the top-right developer HUD.
struct DeveloperDiagnosticsOverlaySnapshot: Equatable, Sendable {
    let overlaysEnabled: Bool
    let loggingEnabled: Bool
    let fields: [DeveloperDiagnosticsField]
    /// Session-scoped context status (OCR). Persists across completion cycles.
    let contextItem: DeveloperDiagnosticsPipelineItem
    /// Per-completion-cycle pipeline stages. Resets on each new work unit.
    let completionItems: [DeveloperDiagnosticsPipelineItem]
    let recentEvents: [DeveloperDiagnosticsEvent]
    let latestAXObserverEvent: FocusObserverEvent?

    static let disabled = DeveloperDiagnosticsOverlaySnapshot(
        overlaysEnabled: false,
        loggingEnabled: false,
        fields: [],
        contextItem: DeveloperDiagnosticsPipelineItem.idle(stage: .ocr),
        completionItems: DeveloperDiagnosticsStage.completionStages.map {
            DeveloperDiagnosticsPipelineItem.idle(stage: $0)
        },
        recentEvents: [],
        latestAXObserverEvent: nil
    )
}
