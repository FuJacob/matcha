import CoreGraphics
import Foundation

/// These are the concrete Accessibility capabilities Matcha needs before it can safely assist a field.
/// The key lesson is that "editable role" is not enough; we care about operational capability.
enum FocusCapabilityRequirement: String, CaseIterable, Equatable {
    case textValue
    case selectionRange
    case caretBounds
    case editableTarget

    var summary: String {
        switch self {
        case .textValue:
            return "Text value"
        case .selectionRange:
            return "Selection range"
        case .caretBounds:
            return "Caret bounds"
        case .editableTarget:
            return "Editable target"
        }
    }

    var unsupportedReason: String {
        "Missing \(summary.lowercased())."
    }
}

/// Distinguishes "unsupported" from "blocked".
/// Unsupported means the host does not expose enough AX data.
/// Blocked means Matcha intentionally refuses to operate, for example in secure fields.
enum FocusCapability: Equatable {
    case supported
    case blocked(String)
    case unsupported(String)

    /// Short labels are better for menu bar UI than long diagnostic sentences.
    var shortLabel: String {
        switch self {
        case .supported:
            return "Supported"
        case .blocked:
            return "Blocked"
        case .unsupported:
            return "Unsupported"
        }
    }

    var summary: String {
        switch self {
        case .supported:
            return "Supported"
        case let .blocked(reason), let .unsupported(reason):
            return reason
        }
    }
}

/// Operator-facing debug information for how the resolver interpreted the AX tree.
struct FocusInspectionSnapshot: Equatable {
    let focusedElementIdentifier: String
    let focusedRole: String
    let focusedSubrole: String?
    let resolvedElementIdentifier: String?
    let resolvedRole: String?
    let resolvedSubrole: String?
    let missingCapabilities: [FocusCapabilityRequirement]

    var focusedRoleSummary: String {
        "\(focusedRole) / \(focusedSubrole ?? "n/a")"
    }

    var resolvedRoleSummary: String {
        guard let resolvedRole else {
            return "Unavailable"
        }

        return "\(resolvedRole) / \(resolvedSubrole ?? "n/a")"
    }

    var missingCapabilitySummary: String {
        guard !missingCapabilities.isEmpty else {
            return "None"
        }

        return missingCapabilities.map(\.summary).joined(separator: ", ")
    }
}

/// This snapshot is the future handoff point into suggestion generation.
/// We store enough information to understand text context and caret placement without generating yet.
struct FocusedInputSnapshot: Equatable {
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

    /// The signature lets later pipeline stages detect whether a completion result is stale.
    /// This is the same idea you would use in a React app with a derived cache key.
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

    var textPreview: String {
        let prefix = String(precedingText.suffix(32))
        let suffix = String(trailingText.prefix(32))
        return "\(prefix)|\(suffix)"
    }
}

/// Top-level focus state that the menu can render directly.
struct FocusSnapshot: Equatable {
    let applicationName: String
    let bundleIdentifier: String?
    let capability: FocusCapability
    let context: FocusedInputSnapshot?
    let inspection: FocusInspectionSnapshot?

    static let inactive = FocusSnapshot(
        applicationName: "No active application",
        bundleIdentifier: nil,
        capability: .unsupported("No focused text input"),
        context: nil,
        inspection: nil
    )

    var capabilitySummary: String {
        capability.summary
    }
}
