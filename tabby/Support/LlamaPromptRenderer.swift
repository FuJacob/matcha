import Foundation

/// File overview:
/// Renders the single prompt string consumed by the local llama runtime.
///
/// Why this file exists:
/// llama.cpp does not give us a separate "instructions" channel the way Foundation Models does.
/// That means all base behavior, user preferences, and request context must be composed into one
/// prompt string. Keeping that composition isolated here prevents prompt policy from leaking into
/// `SuggestionRequestFactory` or the runtime lifecycle layer.
enum LlamaPromptRenderer {
    static func prompt(
        prefixText: String,
        applicationName: String,
        promptMode: SuggestionPromptMode,
        completionLengthInstruction: String,
        customAIInstructions: String?
    ) -> String {
        switch promptMode {
        case .prefixOnly:
            // Fast mode is intentionally the low-overhead path: send only the user's local prefix
            // text. This keeps latency down and minimizes extra steering for short completions.
            return prefixText
        case .guided:
            return guidedPrompt(
                prefixText: prefixText,
                applicationName: applicationName,
                completionLengthInstruction: completionLengthInstruction,
                customAIInstructions: customAIInstructions
            )
        }
    }

    /// The instructions-based mode keeps a more explicit contract for local models that benefit
    /// from stronger task framing, especially when testing how much user guidance the model follows.
    private static func guidedPrompt(
        prefixText: String,
        applicationName: String,
        completionLengthInstruction: String,
        customAIInstructions: String?
    ) -> String {
        var sections = [
            "You are Tabby's inline autocomplete engine for a macOS text field.",
            "",
            "Task:",
            "- Continue the user's existing text exactly at the caret position.",
            "- This is autocomplete, not chat. Do not answer the user or start a conversation.",
            "- Return exactly one continuation fragment.",
            "- Never repeat, restate, or quote the text before the caret.",
            "- \(completionLengthInstruction)",
            "- Match the surrounding language, tone, casing, punctuation, and formatting.",
            "",
            "Output contract:",
            "- Plain text only.",
            "- No labels, bullets, markdown, quotes, or explanation.",
            "- Start immediately with the continuation text."
        ]

        let customInstructionLines = CustomAIInstructionFormatter.promptSectionLines(from: customAIInstructions)
        if !customInstructionLines.isEmpty {
            sections.append("")
            sections.append(contentsOf: customInstructionLines)
        }

        sections.append(contentsOf: [
            "",
            "Context:",
            "App: \(applicationName)",
            "Text before caret:",
            prefixText
        ])

        return sections.joined(separator: "\n")
    }
}
