import Foundation

/// File overview:
/// Defines the product-facing engine choices for Tabby's autocomplete pipeline.
/// This file exists because "which engine is active?" is a domain concept, not a UI-only detail.
///
/// The important architectural distinction is:
/// - a local GGUF file is a model option inside the llama runtime
/// - Apple Intelligence vs. local llama is an engine choice above the runtime layer
enum SuggestionEngineKind: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case appleIntelligence
    case llamaOpenSource

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence"
        case .llamaOpenSource:
            return "Open Source"
        }
    }

    var supportsLocalModelManagement: Bool {
        switch self {
        case .appleIntelligence:
            return false
        case .llamaOpenSource:
            return true
        }
    }
}

/// A user-authored app blocklist entry.
///
/// The bundle identifier is the durable identity used by the suggestion pipeline. The display name
/// is saved only so Settings can show a readable list without having to resolve installed
/// applications again on every launch.
struct DisabledApplicationRule: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

/// Domain overrides need an explicit state because "enabled" is semantically different from
/// "missing rule". A missing rule inherits the browser/app default, while an explicit enabled rule
/// records that the user intentionally wants this domain on even if a broader browser rule later
/// turns off the whole app.
enum DomainOverrideState: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case enabled
    case disabled

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .enabled:
            return "Enabled"
        case .disabled:
            return "Disabled"
        }
    }
}

/// Default domain matching uses the registrable domain (`github.com`), with an opt-in exact-host
/// mode for users who want `docs.github.com` to behave differently from `github.com`.
enum DomainMatchScope: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case registrableDomain
    case exactHost

    var id: String { rawValue }
}

/// Durable browser-domain override authored by the user.
///
/// Both `host` and `registrableDomain` are stored so Settings can switch between broad matching
/// and exact-host matching without re-reading the live browser URL that originally created the rule.
struct DomainOverrideRule: Codable, Equatable, Identifiable, Sendable {
    let host: String
    let registrableDomain: String
    let state: DomainOverrideState
    let matchScope: DomainMatchScope

    var id: String {
        "\(matchScope.rawValue)::\(matchValue)"
    }

    var matchValue: String {
        switch matchScope {
        case .registrableDomain:
            return registrableDomain
        case .exactHost:
            return host
        }
    }

    var displayDomain: String {
        matchValue
    }

    var isSubdomainSpecific: Bool {
        matchScope == .exactHost && host != registrableDomain
    }

    func matches(_ domain: FocusedBrowserDomainIdentity) -> Bool {
        switch matchScope {
        case .registrableDomain:
            return registrableDomain == domain.registrableDomain
        case .exactHost:
            return host == domain.host
        }
    }
}

/// A compact snapshot of the autocomplete settings the coordinator actually needs at generation
/// time. Keeping this as a value type makes change detection simple and deterministic.
struct SuggestionSettingsSnapshot: Equatable, Sendable {
    let isGloballyEnabled: Bool
    let disabledAppBundleIdentifiers: Set<String>
    let domainOverrideRules: [DomainOverrideRule]
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    /// Normalized user-authored guidance for Tabby's instruction-rendered completion prompt.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let customAIInstructions: String?
}
