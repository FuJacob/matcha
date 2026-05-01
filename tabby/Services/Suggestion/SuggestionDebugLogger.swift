import Foundation

/// File overview:
/// Emits high-signal console logs for the suggestion pipeline when `-tabby-debug` is enabled.
/// This logger owns the mechanics of compact summary lines, full prompt/output blocks, and
/// duplicate suppression so the coordinator can focus on state transitions instead of string
/// rendering.
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
        guard TabbyDebugOptions.isEnabled else {
            return
        }

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

        appendPromptPreviewIfNeeded(stage: stage, prompt: prompt, to: &parts)
        appendOutputPreviewIfNeeded(
            stage: stage,
            rawOutput: rawOutput,
            normalizedOutput: normalizedOutput,
            to: &parts
        )

        let summaryLine = parts.joined(separator: " ")
        logLine(summaryLine)

        logPromptBlockIfNeeded(stage: stage, workID: workID, generation: generation, prompt: prompt)
        logOutputBlocksIfNeeded(
            stage: stage,
            workID: workID,
            generation: generation,
            rawOutput: rawOutput,
            normalizedOutput: normalizedOutput
        )
    }

    private func appendPromptPreviewIfNeeded(
        stage: String,
        prompt: String?,
        to parts: inout [String]
    ) {
        guard stage == "generating", let prompt else {
            return
        }

        parts.append("prompt=\(Self.debugPreview(prompt))")
    }

    private func appendOutputPreviewIfNeeded(
        stage: String,
        rawOutput: String?,
        normalizedOutput: String?,
        to parts: inout [String]
    ) {
        guard stage != "generating" else {
            return
        }

        switch (rawOutput, normalizedOutput) {
        case let (raw?, normalized?):
            appendPairedOutputPreview(raw: raw, normalized: normalized, to: &parts)
        case let (raw?, nil):
            parts.append("rawOutput=\(Self.debugPreview(raw))")
        case let (nil, normalized?):
            parts.append("normalizedOutput=\(Self.debugPreview(normalized))")
        case (nil, nil):
            break
        }
    }

    private func appendPairedOutputPreview(
        raw: String,
        normalized: String,
        to parts: inout [String]
    ) {
        // When generation and normalization diverge, surface both previews in the compact summary
        // so we can immediately see whether cleanup stripped backend output away.
        if raw == normalized {
            parts.append("output=\(Self.debugPreview(raw))")
        } else {
            parts.append("rawOutput=\(Self.debugPreview(raw))")
            parts.append("normalizedOutput=\(Self.debugPreview(normalized))")
        }
    }

    private func logPromptBlockIfNeeded(
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        prompt: String?
    ) {
        guard stage == "generating", let prompt else {
            return
        }

        logTextBlock(
            kind: "prompt",
            stage: stage,
            workID: workID,
            generation: generation,
            text: prompt
        )
    }

    private func logOutputBlocksIfNeeded(
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        rawOutput: String?,
        normalizedOutput: String?
    ) {
        guard stage != "generating" else {
            return
        }

        switch (rawOutput, normalizedOutput) {
        case let (raw?, normalized?):
            logPairedOutputBlocks(
                stage: stage,
                workID: workID,
                generation: generation,
                raw: raw,
                normalized: normalized
            )
        case let (raw?, nil):
            logTextBlock(kind: "raw-output", stage: stage, workID: workID, generation: generation, text: raw)
        case let (nil, normalized?):
            logTextBlock(
                kind: "normalized-output",
                stage: stage,
                workID: workID,
                generation: generation,
                text: normalized
            )
        case (nil, nil):
            break
        }
    }

    private func logPairedOutputBlocks(
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        raw: String,
        normalized: String
    ) {
        if raw == normalized {
            logTextBlock(kind: "output", stage: stage, workID: workID, generation: generation, text: raw)
        } else {
            logTextBlock(kind: "raw-output", stage: stage, workID: workID, generation: generation, text: raw)
            logTextBlock(
                kind: "normalized-output",
                stage: stage,
                workID: workID,
                generation: generation,
                text: normalized
            )
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
        TabbyDebugOptions.log(line)
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
        TabbyDebugOptions.log(
            """
            [Suggestion \(kind)] stage=\(stage) work=\(workID) generation=\(generationSummary)
            ----- BEGIN \(kind.uppercased()) -----
            \(renderedText)
            ----- END \(kind.uppercased()) -----
            """
        )
    }
}
