import Foundation

/// File overview:
/// Emits high-signal console logs for the suggestion pipeline. This logger owns the mechanics of
/// compact summary lines, full prompt/output blocks, and duplicate suppression so the coordinator
/// can focus on state transitions instead of string rendering.
///
/// Logging is intentionally stateful because duplicate suppression depends on the previously
/// emitted line. Keeping that state here avoids scattering "did we already print this?" checks
/// through `SuggestionCoordinator`.
@MainActor
final class SuggestionDebugLogger {
    private let consoleStages: Set<String>
    private var lastLoggedMessage: String?

    init(
        consoleStages: Set<String> = [
            "generating",
            "ready",
            "empty-result",
            "failed",
            "tab-accepted-chunk",
            "tab-accepted-final-chunk",
            "typed-match-advanced",
            "typed-match-exhausted",
            "session-reconciled",
            "session-exhausted"
        ]
    ) {
        self.consoleStages = consoleStages
    }

    /// Emits a compact one-line summary and, when useful, the full prompt/output payload.
    func logStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64? = nil,
        message: String,
        prompt: String? = nil,
        rawOutput: String? = nil,
        normalizedOutput: String? = nil
    ) {
        guard consoleStages.contains(stage) else {
            return
        }

        var parts = [
            "[Suggestion]",
            "stage=\(stage)",
            "work=\(workID)"
        ]

        if let generation {
            parts.append("generation=\(generation)")
        }

        parts.append("message=\(message)")

        if stage == "generating", let prompt {
            parts.append("prompt=\(Self.debugPreview(prompt))")
        }

        if stage != "generating" {
            appendOutputSummaryParts(
                to: &parts,
                rawOutput: rawOutput,
                normalizedOutput: normalizedOutput
            )
        }

        logLine(parts.joined(separator: " "))

        if stage == "generating", let prompt {
            logTextBlock(kind: "prompt", stage: stage, workID: workID, generation: generation, text: prompt)
        }

        if stage != "generating" {
            logOutputBlocks(
                stage: stage,
                workID: workID,
                generation: generation,
                rawOutput: rawOutput,
                normalizedOutput: normalizedOutput
            )
        }
    }

    /// Appends compact output preview tokens to the running summary parts array.
    /// Extracted to keep `logStage` cyclomatic complexity within the configured limit.
    private func appendOutputSummaryParts(
        to parts: inout [String],
        rawOutput: String?,
        normalizedOutput: String?
    ) {
        switch (rawOutput, normalizedOutput) {
        case let (raw?, normalized?):
            // When generation and normalization diverge, surface both previews in the compact
            // summary so we can immediately see whether the backend returned text that the
            // cleanup layer later stripped away.
            if raw == normalized {
                parts.append("output=\(Self.debugPreview(raw))")
            } else {
                parts.append("rawOutput=\(Self.debugPreview(raw))")
                parts.append("normalizedOutput=\(Self.debugPreview(normalized))")
            }
        case let (raw?, nil):
            parts.append("rawOutput=\(Self.debugPreview(raw))")
        case let (nil, normalized?):
            parts.append("normalizedOutput=\(Self.debugPreview(normalized))")
        case (nil, nil):
            break
        }
    }

    /// Emits full multi-line output blocks for a non-generating stage.
    /// Extracted to keep `logStage` cyclomatic complexity within the configured limit.
    private func logOutputBlocks(
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        rawOutput: String?,
        normalizedOutput: String?
    ) {
        switch (rawOutput, normalizedOutput) {
        case let (raw?, normalized?):
            if raw == normalized {
                logTextBlock(kind: "output", stage: stage, workID: workID, generation: generation, text: raw)
            } else {
                logTextBlock(kind: "raw-output", stage: stage, workID: workID, generation: generation, text: raw)
                logTextBlock(kind: "normalized-output", stage: stage, workID: workID, generation: generation, text: normalized)
            }
        case let (raw?, nil):
            logTextBlock(kind: "raw-output", stage: stage, workID: workID, generation: generation, text: raw)
        case let (nil, normalized?):
            logTextBlock(kind: "normalized-output", stage: stage, workID: workID, generation: generation, text: normalized)
        case (nil, nil):
            break
        }
    }

    /// Produces an escaped single-line preview suitable for compact logs and menu summaries.
    static func debugPreview(_ text: String) -> String {
        if text.isEmpty {
            return "<empty>"
        }

        let escaped = text.debugDescription
        if escaped.count <= 160 {
            return escaped
        }

        let index = escaped.index(escaped.startIndex, offsetBy: 160)
        return "\(escaped[..<index])..."
    }

    private func logLine(_ line: String) {
        guard line != lastLoggedMessage else {
            return
        }

        lastLoggedMessage = line
        print(line)
    }

    /// Compact one-line logs are good for scanning, but prompt debugging requires the exact payload.
    /// We print the full block here so maintainers can inspect the precise prompt or output text.
    private func logTextBlock(
        kind: String,
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        text: String
    ) {
        let generationSummary = generation.map(String.init) ?? "n/a"
        let renderedText = text.isEmpty ? "<empty>" : text
        // Multi-line log blocks are easier to inspect than escaped one-line strings when debugging
        // prompt construction or output normalization.
        print(
            """
            [Suggestion \(kind)] stage=\(stage) work=\(workID) generation=\(generationSummary)
            ----- BEGIN \(kind.uppercased()) -----
            \(renderedText)
            ----- END \(kind.uppercased()) -----
            """
        )
    }
}
