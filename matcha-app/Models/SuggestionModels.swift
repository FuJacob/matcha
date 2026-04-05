import CoreGraphics
import Foundation

/// Debug defaults live in one place so the first prediction slice has deterministic behavior.
struct SuggestionConfiguration: Equatable {
    let maxPredictionTokens: Int
    let debounceMilliseconds: Int
    let temperature: Double
    let topP: Double
    let maxPrefixCharacters: Int
    let maxSuffixCharacters: Int

    static let debugDefaults = SuggestionConfiguration(
        // Short completions are dramatically cheaper than long ones and feel better for inline UX.
        maxPredictionTokens: 12,
        // A tiny debounce still gives the host app time to update AX text state after a key press.
        debounceMilliseconds: 90,
        temperature: 0.15,
        topP: 0.85,
        // Prompt windows should stay small. Sending an entire Xcode buffer kills latency for no gain.
        maxPrefixCharacters: 192,
        maxSuffixCharacters: 48
    )
}

/// This is the stable context used across debounce and generation boundaries.
/// It extends the AX snapshot with a monotonically increasing generation number.
struct FocusedInputContext: Equatable {
    let applicationName: String
    let bundleIdentifier: String
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let caretRect: CGRect
    let precedingText: String
    let trailingText: String
    let selection: NSRange
    let isSecure: Bool
    let generation: UInt64

    init(snapshot: FocusedInputSnapshot, generation: UInt64) {
        applicationName = snapshot.applicationName
        bundleIdentifier = snapshot.bundleIdentifier
        elementIdentifier = snapshot.elementIdentifier
        role = snapshot.role
        subrole = snapshot.subrole
        caretRect = snapshot.caretRect
        precedingText = snapshot.precedingText
        trailingText = snapshot.trailingText
        selection = snapshot.selection
        isSecure = snapshot.isSecure
        self.generation = generation
    }

    var contentSignature: String {
        [
            elementIdentifier,
            String(selection.location),
            String(selection.length),
            precedingText,
            trailingText,
            isSecure ? "secure" : "plain"
        ].joined(separator: "::")
    }
}

struct SuggestionRequest: Equatable {
    let context: FocusedInputContext
    let prompt: String
    let generation: UInt64
    let maxPredictionTokens: Int
    let temperature: Double
    let topP: Double
}

struct SuggestionResult: Equatable {
    let generation: UInt64
    let rawText: String
    let text: String
    let latency: TimeInterval
    let finishReason: String
}

enum SuggestionDebugState: Equatable {
    case idle
    case disabled(String)
    case debouncing
    case generating
    case ready(text: String, latency: TimeInterval)
    case failed(String)

    var shortLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .disabled:
            return "Disabled"
        case .debouncing:
            return "Debouncing"
        case .generating:
            return "Generating"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    var detail: String? {
        switch self {
        case .idle:
            return "No active suggestion is currently available."
        case let .disabled(reason), let .failed(reason):
            return reason
        case .debouncing:
            return "Waiting for typing to settle."
        case .generating:
            return "Requesting a completion from the local runtime."
        case .ready:
            return "Ready means Matcha has buffered a non-empty normalized completion for this field and can render it as ghost text."
        }
    }
}

/// The overlay is intentionally modeled as data so diagnostics can reason about visibility
/// without poking into AppKit window objects directly.
enum OverlayState: Equatable {
    case hidden(reason: String)
    case visible(text: String, caretRect: CGRect)

    var shortLabel: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .visible:
            return "Visible"
        }
    }

    var detail: String {
        switch self {
        case let .hidden(reason):
            return reason
        case let .visible(text, caretRect):
            return "Showing \(text.count) characters near (\(Int(caretRect.minX)), \(Int(caretRect.minY)))."
        }
    }

    var isVisible: Bool {
        if case .visible = self {
            return true
        }

        return false
    }

    var visibleText: String? {
        guard case let .visible(text, _) = self else {
            return nil
        }

        return text
    }
}

enum SuggestionClientError: LocalizedError {
    case unavailable(String)
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .generationFailed(message):
            return message
        case .cancelled:
            return "Generation was cancelled."
        }
    }
}
