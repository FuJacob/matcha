import Combine
import Foundation

/// File overview:
/// Owns the durable autocomplete preferences that are shared across the app:
/// engine selection, completion length, indicator appearance, and custom
/// writing guidance.
///
/// This type is the right owner for these values because they are product settings, not
/// `SuggestionCoordinator` session state. The coordinator should react to settings changes, not
/// persist them itself.
@MainActor
final class SuggestionSettingsModel: ObservableObject {
    @Published private(set) var isGloballyEnabled: Bool
    @Published private(set) var selectedIndicatorMode: ActivationIndicatorMode
    @Published private(set) var disabledAppRules: [DisabledApplicationRule]
    @Published private(set) var domainOverrideRules: [DomainOverrideRule]
    @Published private(set) var customSuggestionTextColorHex: String?
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    @Published private(set) var customAIInstructions: String

    private let userDefaults: UserDefaults

    private static let isGloballyEnabledDefaultsKey = "tabbyGloballyEnabled"
    private static let disabledAppRulesDefaultsKey = "tabbyDisabledAppRules"
    private static let domainOverrideRulesDefaultsKey = "tabbyDomainOverrideRules"
    // Legacy key. Keep reading and writing through it so old builds degrade to a visible indicator.
    private static let showCaretIndicatorDefaultsKey = "tabbyShowCaretIndicator"
    private static let selectedIndicatorModeDefaultsKey = "tabbySelectedIndicatorMode"
    private static let customSuggestionTextColorHexDefaultsKey = "tabbyCustomSuggestionTextColorHex"
    private static let selectedEngineDefaultsKey = "selectedSuggestionEngine"
    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let customAIInstructionsDefaultsKey = "tabbyCustomAIInstructions"

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults

        let resolvedGloballyEnabled = userDefaults.object(forKey: Self.isGloballyEnabledDefaultsKey) as? Bool ?? true
        let resolvedDisabledAppRules = Self.loadDisabledAppRules(from: userDefaults)
        let resolvedDomainOverrideRules = Self.loadDomainOverrideRules(from: userDefaults)
        let legacyShowCaretIndicator = userDefaults.object(forKey: Self.showCaretIndicatorDefaultsKey) as? Bool ?? true
        let resolvedIndicatorMode = userDefaults
            .string(forKey: Self.selectedIndicatorModeDefaultsKey)
            .flatMap(ActivationIndicatorMode.init(rawValue:))
            ?? Self.migrateIndicatorMode(fromLegacyShowCaretIndicator: legacyShowCaretIndicator)
        let resolvedCustomSuggestionTextColorHex = Self.normalizedHexString(
            userDefaults.string(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        )
        let resolvedEngine = userDefaults
            .string(forKey: Self.selectedEngineDefaultsKey)
            .flatMap(SuggestionEngineKind.init(rawValue:))
            ?? .llamaOpenSource
        let resolvedWordCountPreset = userDefaults
            .string(forKey: Self.selectedWordCountPresetDefaultsKey)
            .flatMap(SuggestionWordCountPreset.init(rawValue:))
            ?? configuration.defaultWordCountPreset
        let resolvedCustomAIInstructions: String = if userDefaults.object(forKey: Self.customAIInstructionsDefaultsKey) == nil {
            configuration.defaultCustomAIInstructions ?? ""
        } else {
            userDefaults.string(forKey: Self.customAIInstructionsDefaultsKey) ?? ""
        }

        isGloballyEnabled = resolvedGloballyEnabled
        disabledAppRules = resolvedDisabledAppRules
        domainOverrideRules = resolvedDomainOverrideRules
        selectedIndicatorMode = resolvedIndicatorMode
        customSuggestionTextColorHex = resolvedCustomSuggestionTextColorHex
        selectedEngine = resolvedEngine
        selectedWordCountPreset = resolvedWordCountPreset
        customAIInstructions = resolvedCustomAIInstructions

        userDefaults.set(resolvedGloballyEnabled, forKey: Self.isGloballyEnabledDefaultsKey)
        persistDisabledAppRules(resolvedDisabledAppRules)
        persistDomainOverrideRules(resolvedDomainOverrideRules)
        persistSelectedIndicatorMode(resolvedIndicatorMode)
        persistCustomSuggestionTextColorHex(resolvedCustomSuggestionTextColorHex)
        persistSelectedEngine(resolvedEngine)
        persistSelectedWordCountPreset(resolvedWordCountPreset)
        persistCustomAIInstructions(resolvedCustomAIInstructions)
    }

    /// Compatibility shim for legacy call sites while the UI migrates from the old toggle to the
    /// richer indicator-mode picker.
    var showCaretIndicator: Bool {
        selectedIndicatorMode != .hidden
    }

    var snapshot: SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            isGloballyEnabled: isGloballyEnabled,
            disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
            domainOverrideRules: domainOverrideRules,
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            customAIInstructions: CustomAIInstructionFormatter.normalized(customAIInstructions)
        )
    }

    func selectEngine(_ engine: SuggestionEngineKind) {
        guard selectedEngine != engine else {
            return
        }

        selectedEngine = engine
        persistSelectedEngine(engine)
    }

    func selectWordCountPreset(_ preset: SuggestionWordCountPreset) {
        guard selectedWordCountPreset != preset else {
            return
        }

        selectedWordCountPreset = preset
        persistSelectedWordCountPreset(preset)
    }

    func setGloballyEnabled(_ enabled: Bool) {
        guard isGloballyEnabled != enabled else {
            return
        }

        isGloballyEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isGloballyEnabledDefaultsKey)
    }

    func setApplicationDisabled(
        bundleIdentifier: String?,
        displayName: String,
        disabled: Bool
    ) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) else {
            return
        }

        if disabled {
            disableApplication(
                bundleIdentifier: normalizedBundleIdentifier,
                displayName: displayName
            )
        } else {
            removeDisabledApplication(bundleIdentifier: normalizedBundleIdentifier)
        }
    }

    func disableApplication(
        bundleIdentifier: String,
        displayName: String
    ) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) else {
            return
        }

        let normalizedDisplayName = Self.normalizedDisplayName(
            displayName,
            fallbackBundleIdentifier: normalizedBundleIdentifier
        )
        let rule = DisabledApplicationRule(
            bundleIdentifier: normalizedBundleIdentifier,
            displayName: normalizedDisplayName
        )
        var updatedRulesByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: disabledAppRules.map { ($0.bundleIdentifier, $0) }
        )
        updatedRulesByBundleIdentifier[normalizedBundleIdentifier] = rule
        let updatedRules = Self.sortedDisabledAppRules(Array(updatedRulesByBundleIdentifier.values))

        guard disabledAppRules != updatedRules else {
            return
        }

        disabledAppRules = updatedRules
        persistDisabledAppRules(updatedRules)
    }

    func removeDisabledApplication(bundleIdentifier: String?) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        else {
            return
        }

        let updatedRules = disabledAppRules.filter {
            $0.bundleIdentifier != normalizedBundleIdentifier
        }

        guard disabledAppRules != updatedRules else {
            return
        }

        disabledAppRules = updatedRules
        persistDisabledAppRules(updatedRules)
    }

    func isApplicationDisabled(bundleIdentifier: String?) -> Bool {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        else {
            return false
        }

        return disabledAppRules.contains {
            $0.bundleIdentifier == normalizedBundleIdentifier
        }
    }

    /// Finds the most specific matching rule for the current browser tab.
    ///
    /// Exact-host overrides win over registrable-domain overrides because they represent a more
    /// specific user intent.
    func domainOverrideRule(
        for domain: FocusedBrowserDomainIdentity
    ) -> DomainOverrideRule? {
        if let exactHostRule = domainOverrideRules.first(where: {
            $0.matchScope == .exactHost && $0.matches(domain)
        }) {
            return exactHostRule
        }

        return domainOverrideRules.first(where: {
            $0.matchScope == .registrableDomain && $0.matches(domain)
        })
    }

    func setDomainOverride(
        for domain: FocusedBrowserDomainIdentity,
        state: DomainOverrideState
    ) {
        let existingRule = domainOverrideRule(for: domain)
        let updatedRule = DomainOverrideRule(
            host: Self.normalizedHost(domain.host),
            registrableDomain: Self.normalizedHost(domain.registrableDomain),
            state: state,
            matchScope: existingRule?.matchScope ?? .registrableDomain
        )

        upsertDomainOverrideRule(
            updatedRule,
            replacingRuleWithID: existingRule?.id
        )
    }

    func setDomainOverrideState(
        ruleID: String,
        state: DomainOverrideState
    ) {
        guard let existingRule = domainOverrideRules.first(where: { $0.id == ruleID }) else {
            return
        }

        let updatedRule = DomainOverrideRule(
            host: existingRule.host,
            registrableDomain: existingRule.registrableDomain,
            state: state,
            matchScope: existingRule.matchScope
        )
        upsertDomainOverrideRule(updatedRule, replacingRuleWithID: existingRule.id)
    }

    func setDomainOverrideUsesExactHost(
        ruleID: String,
        usesExactHost: Bool
    ) {
        guard let existingRule = domainOverrideRules.first(where: { $0.id == ruleID }) else {
            return
        }

        let updatedScope: DomainMatchScope = usesExactHost ? .exactHost : .registrableDomain
        let updatedRule = DomainOverrideRule(
            host: existingRule.host,
            registrableDomain: existingRule.registrableDomain,
            state: existingRule.state,
            matchScope: updatedScope
        )
        upsertDomainOverrideRule(updatedRule, replacingRuleWithID: existingRule.id)
    }

    func removeDomainOverride(ruleID: String) {
        let updatedRules = domainOverrideRules.filter {
            $0.id != ruleID
        }

        guard updatedRules != domainOverrideRules else {
            return
        }

        domainOverrideRules = updatedRules
        persistDomainOverrideRules(updatedRules)
    }

    func selectIndicatorMode(_ mode: ActivationIndicatorMode) {
        guard selectedIndicatorMode != mode else {
            return
        }

        selectedIndicatorMode = mode
        persistSelectedIndicatorMode(mode)
    }

    /// Compatibility shim for old toggle-driven call sites. Turning the toggle back on restores the
    /// caret-anchor indicator because that was the historic behavior users opted into.
    func setShowCaretIndicator(_ show: Bool) {
        selectIndicatorMode(show ? .caretAnchor : .hidden)
    }

    func setCustomSuggestionTextColorHex(_ hex: String?) {
        let normalizedHex = Self.normalizedHexString(hex)
        guard customSuggestionTextColorHex != normalizedHex else {
            return
        }

        customSuggestionTextColorHex = normalizedHex
        persistCustomSuggestionTextColorHex(normalizedHex)
    }

    func setCustomAIInstructions(_ instructions: String) {
        guard customAIInstructions != instructions else {
            return
        }

        customAIInstructions = instructions
        persistCustomAIInstructions(instructions)
    }

    private func persistSelectedEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.selectedEngineDefaultsKey)
    }

    private func persistSelectedWordCountPreset(_ preset: SuggestionWordCountPreset) {
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
    }

    private func persistSelectedIndicatorMode(_ mode: ActivationIndicatorMode) {
        userDefaults.set(mode.rawValue, forKey: Self.selectedIndicatorModeDefaultsKey)
        userDefaults.set(mode != .hidden, forKey: Self.showCaretIndicatorDefaultsKey)
    }

    private func persistCustomSuggestionTextColorHex(_ hex: String?) {
        if let hex {
            userDefaults.set(hex, forKey: Self.customSuggestionTextColorHexDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        }
    }

    private static func migrateIndicatorMode(
        fromLegacyShowCaretIndicator showCaretIndicator: Bool
    ) -> ActivationIndicatorMode {
        showCaretIndicator ? .caretAnchor : .hidden
    }

    private static func loadDisabledAppRules(from userDefaults: UserDefaults) -> [DisabledApplicationRule] {
        guard let data = userDefaults.data(forKey: Self.disabledAppRulesDefaultsKey),
              let decodedRules = try? JSONDecoder().decode([DisabledApplicationRule].self, from: data)
        else {
            return []
        }

        return sanitizedDisabledAppRules(decodedRules)
    }

    private static func loadDomainOverrideRules(from userDefaults: UserDefaults) -> [DomainOverrideRule] {
        guard let data = userDefaults.data(forKey: Self.domainOverrideRulesDefaultsKey),
              let decodedRules = try? JSONDecoder().decode([DomainOverrideRule].self, from: data)
        else {
            return []
        }

        return sanitizedDomainOverrideRules(decodedRules)
    }

    private static func sanitizedDisabledAppRules(
        _ rules: [DisabledApplicationRule]
    ) -> [DisabledApplicationRule] {
        var rulesByBundleIdentifier: [String: DisabledApplicationRule] = [:]

        for rule in rules {
            guard let normalizedBundleIdentifier = normalizedBundleIdentifier(rule.bundleIdentifier)
            else {
                continue
            }

            rulesByBundleIdentifier[normalizedBundleIdentifier] = DisabledApplicationRule(
                bundleIdentifier: normalizedBundleIdentifier,
                displayName: normalizedDisplayName(
                    rule.displayName,
                    fallbackBundleIdentifier: normalizedBundleIdentifier
                )
            )
        }

        return sortedDisabledAppRules(Array(rulesByBundleIdentifier.values))
    }

    private static func sortedDisabledAppRules(
        _ rules: [DisabledApplicationRule]
    ) -> [DisabledApplicationRule] {
        rules.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }

            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func sanitizedDomainOverrideRules(
        _ rules: [DomainOverrideRule]
    ) -> [DomainOverrideRule] {
        var rulesByIdentifier: [String: DomainOverrideRule] = [:]

        for rule in rules {
            let sanitizedHost = normalizedHost(rule.host)
            let sanitizedRegistrableDomain = normalizedHost(rule.registrableDomain)
            guard !sanitizedHost.isEmpty, !sanitizedRegistrableDomain.isEmpty else {
                continue
            }

            let sanitizedRule = DomainOverrideRule(
                host: sanitizedHost,
                registrableDomain: sanitizedRegistrableDomain,
                state: rule.state,
                matchScope: rule.matchScope
            )
            rulesByIdentifier[sanitizedRule.id] = sanitizedRule
        }

        return sortedDomainOverrideRules(Array(rulesByIdentifier.values))
    }

    private static func sortedDomainOverrideRules(
        _ rules: [DomainOverrideRule]
    ) -> [DomainOverrideRule] {
        rules.sorted {
            if $0.displayDomain.localizedCaseInsensitiveCompare($1.displayDomain) == .orderedSame {
                return $0.id < $1.id
            }

            return $0.displayDomain.localizedCaseInsensitiveCompare($1.displayDomain)
                == .orderedAscending
        }
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else {
            return nil
        }

        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedDisplayName(
        _ displayName: String,
        fallbackBundleIdentifier: String
    ) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackBundleIdentifier : trimmed
    }

    private static func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
    }

    private static func normalizedHexString(_ hex: String?) -> String? {
        guard let hex else {
            return nil
        }

        let trimmed = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        let validCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard trimmed.count == 6,
              trimmed.unicodeScalars.allSatisfy(validCharacters.contains(_:))
        else {
            return nil
        }

        return trimmed
    }

    private func persistCustomAIInstructions(_ instructions: String) {
        userDefaults.set(instructions, forKey: Self.customAIInstructionsDefaultsKey)
    }

    private func persistDisabledAppRules(_ rules: [DisabledApplicationRule]) {
        guard !rules.isEmpty else {
            userDefaults.removeObject(forKey: Self.disabledAppRulesDefaultsKey)
            return
        }

        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: Self.disabledAppRulesDefaultsKey)
        }
    }

    private func persistDomainOverrideRules(_ rules: [DomainOverrideRule]) {
        guard !rules.isEmpty else {
            userDefaults.removeObject(forKey: Self.domainOverrideRulesDefaultsKey)
            return
        }

        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: Self.domainOverrideRulesDefaultsKey)
        }
    }

    private func upsertDomainOverrideRule(
        _ rule: DomainOverrideRule,
        replacingRuleWithID replacedRuleID: String?
    ) {
        var updatedRules = domainOverrideRules.filter { existingRule in
            existingRule.id != rule.id && existingRule.id != replacedRuleID
        }
        updatedRules.append(rule)
        let sortedRules = Self.sortedDomainOverrideRules(updatedRules)

        guard sortedRules != domainOverrideRules else {
            return
        }

        domainOverrideRules = sortedRules
        persistDomainOverrideRules(sortedRules)
    }
}

extension SuggestionSettingsModel: SuggestionSettingsProviding {
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                $isGloballyEnabled,
                $disabledAppRules,
                $domainOverrideRules,
                $selectedEngine
            ),
            Publishers.CombineLatest(
                $selectedWordCountPreset,
                $customAIInstructions
            )
        )
        .map { combinedSettings, secondarySettings in
            let (globallyEnabled, disabledAppRules, domainOverrideRules, engine) = combinedSettings
            let (wordCountPreset, customAIInstructions) = secondarySettings
            return SuggestionSettingsSnapshot(
                isGloballyEnabled: globallyEnabled,
                disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
                domainOverrideRules: domainOverrideRules,
                selectedEngine: engine,
                selectedWordCountPreset: wordCountPreset,
                customAIInstructions: CustomAIInstructionFormatter.normalized(customAIInstructions)
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
