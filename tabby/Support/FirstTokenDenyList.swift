import Foundation

/// File overview:
/// Declarative first-token deny lists for suppressing chat residue from instruction-tuned models.
///
/// When instruction-tuned models (Gemma-instruct, Qwen3, etc.) are used for inline autocomplete,
/// they sometimes begin their response with conversational tokens that belong to a "helpful
/// assistant" reply rather than the user's text continuation — phrases like "Sure,", "Here's",
/// "Of course", or a leading newline.
///
/// This file defines the human-readable deny strings. The strings are resolved to concrete token
/// IDs at model-load time inside `LlamaRuntimeCore`, since tokenization depends on the loaded
/// model's vocabulary.
///
/// Why this list is small and conservative:
/// the gate is a hard `-inf` mask — every entry is a permanent block at position 0 with no
/// soft-bias fallback. False positives matter. The list intentionally only contains tokens that
/// are *almost never* the right continuation of arbitrary typed text:
///   - "Sure", "Of course", "Certainly" — pure politeness openers, no prose use case at position 0
///   - "Here"   — chat residue ("Here's…", "Here is…"); rarely starts a continuation otherwise
///   - "\n"     — leading-newline reflex from instruct prompting; usually noise, not signal
///
/// Notably *not* on the list (despite being suggestive in the issue):
///   - "I " — high false-positive rate in real prose ("I went to…", "I think…")
///   - "Let me" / "Let" — "Let's" and similar legitimate continuations would also collide
///   - Language-specific openers ("好的", "当然") — no measurement yet to back them
///
/// The debug log under subsystem=app.tabby category=first-token-gate fires whenever the un-gated
/// argmax of the raw logits at position 0 is in this list. That's the data we need to grow this
/// list deliberately rather than by intuition.
///
/// Architectural placement: `Support/` because this is pure, deterministic data with no side
/// effects, runtime dependencies, or OS interactions. It changes at a different rate than
/// the runtime code that consumes it.

/// Provides deny lists of strings that should never appear as the first generated token during
/// inline autocomplete. Each string represents a chat-residue opener that instruction-tuned
/// models commonly emit when the prompt looks conversational.
enum FirstTokenDenyList {

    /// Returns the deny strings for the given model filename.
    ///
    /// Today every known and unknown model gets the same conservative list. The per-model
    /// switch is kept as the extension point: once the debug log gives us evidence that a
    /// specific model has a different residue profile (e.g. Qwen3 emitting Chinese openers
    /// frequently in this code path), we add a model-specific case here without changing
    /// the runtime resolution path.
    ///
    /// - Parameter modelFilename: The basename of the loaded GGUF file (e.g. "gemma-3-1b-it-Q4_K_M.gguf").
    /// - Returns: An array of strings whose leading token(s) should be denied at generation position 0.
    static func denyStrings(for modelFilename: String) -> [String] {
        switch modelFilename {
        case "gemma-3-1b-it-Q4_K_M.gguf",
             "gemma-3n-E4B-it-Q4_K_M.gguf",
             "Qwen3-0.6B-Q4_K_M.gguf":
            return Self.conservativeDenyStrings
        default:
            return Self.conservativeDenyStrings
        }
    }

    // MARK: - Deny Lists

    /// The starting list. Every entry is an opener that has essentially no legitimate use as the
    /// *first* token of an inline-autocomplete continuation. Grow this only with evidence from the
    /// gate-fire debug log, not from intuition.
    private static let conservativeDenyStrings: [String] = [
        "Sure",
        "Here",
        "Of course",
        "Certainly",
        "\n"
    ]
}
