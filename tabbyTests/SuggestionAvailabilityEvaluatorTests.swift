import Combine
import XCTest
@testable import tabby

/// Tests for the gate every coordinator path runs through before starting a
/// generation. The value of concentrating these checks in one function is
/// precisely that UI copy and the gate logic can't drift; these tests lock
/// that contract in.
final class SuggestionAvailabilityEvaluatorTests: XCTestCase {

    // Build a FocusSnapshot with only the capability varied — none of the gate
    // logic we're testing here touches `context` or `inspection`, so leaving
    // them nil keeps each test focused on the single axis under test.
    private func makeSnapshot(
        applicationName: String = "TestApp",
        bundleIdentifier: String? = "app.test",
        capability: FocusCapability
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: capability,
            context: nil,
            inspection: nil
        )
    }

    // MARK: - disabledReason: exact-string contracts

    /// If this string ever changes, the menu-bar status copy will silently
    /// change alongside it. Pin it so any copy edit is deliberate.
    func test_disabledReason_whenGloballyDisabled_returnsFixedCopy() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Tabby is turned off.")
    }

    func test_disabledReason_whenInputMonitoringDenied_mentionsPermission() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: false,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Input Monitoring") ?? false,
                      "reason should point the user at the permission they need to grant")
    }

    // MARK: - disabledReason: guard ordering

    /// Global-off takes precedence over permission-denied. Important because
    /// the copy the user sees should be the thing they most need to know; if
    /// Tabby is off, the Input Monitoring message is a distraction.
    func test_disabledReason_globalDisabled_winsOverInputMonitoringDenied() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: false,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Tabby is turned off.")
    }

    func test_disabledReason_globalDisabled_winsOverAppDisabled() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            disabledAppBundleIdentifiers: ["app.test"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Tabby is turned off.")
    }

    func test_disabledReason_whenAppDisabled_returnsAppSpecificCopy() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            disabledAppBundleIdentifiers: ["com.apple.Safari"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                capability: .supported
            )
        )

        XCTAssertEqual(reason, "Tabby is disabled in Safari.")
    }

    // MARK: - disabledReason: capability passthrough

    /// The .blocked and .unsupported cases both surface their own reason
    /// string so the menu can explain which field Tabby is refusing to
    /// handle. Test that the evaluator passes these through verbatim.
    func test_disabledReason_blockedCapability_returnsCapabilityReason() {
        let blockReason = "Secure field — Tabby intentionally won't run here."
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .blocked(blockReason))
        )

        XCTAssertEqual(reason, blockReason)
    }

    func test_disabledReason_unsupportedCapability_returnsCapabilityReason() {
        let unsupportedReason = "No focused text input"
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .unsupported(unsupportedReason))
        )

        XCTAssertEqual(reason, unsupportedReason)
    }

    // MARK: - disabledReason: happy path

    func test_disabledReason_whenEverythingAllowed_returnsNil() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertNil(reason)
    }

    // MARK: - shouldSchedulePrediction (boolean wrapper)

    /// shouldSchedulePrediction is the bool collapse of disabledReason == nil.
    /// Tests both sides of the nil boundary so a future refactor of one
    /// function without the other would trip.
    func test_shouldSchedulePrediction_trueWhenNoDisabledReason() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertTrue(ok)
    }

    func test_shouldSchedulePrediction_falseWhenGloballyDisabled() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertFalse(ok)
    }

    func test_shouldSchedulePrediction_falseWhenAppDisabled() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            disabledAppBundleIdentifiers: ["app.test"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertFalse(ok)
    }

    func test_shouldSchedulePrediction_trueWhenDifferentAppDisabled() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            disabledAppBundleIdentifiers: ["app.other"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertTrue(ok)
    }

    func test_shouldSchedulePrediction_falseWhenCapabilityUnsupported() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .unsupported("No focused text input"))
        )

        XCTAssertFalse(ok)
    }
}

/// Tests for the app identity that menu-bar controls target.
///
/// This is deliberately a pure model test instead of a SwiftUI test. The behavior we care about is
/// not pixels; it is the invariant that Tabby's own transient focus does not become the app rule
/// target after the user opens the menu bar.
final class FocusSnapshotExternalApplicationIdentityTests: XCTestCase {
    func test_externalApplicationIdentity_returnsNonTabbyApplication() {
        let snapshot = FocusSnapshot(
            applicationName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            capability: .supported,
            context: nil,
            inspection: nil
        )

        XCTAssertEqual(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby"),
            FocusedApplicationIdentity(
                applicationName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        )
    }

    func test_externalApplicationIdentity_ignoresTabbyApplication() {
        let snapshot = FocusSnapshot(
            applicationName: "Tabby",
            bundleIdentifier: "com.jacobfu.tabby",
            capability: .blocked("Tabby is focused."),
            context: nil,
            inspection: nil
        )

        XCTAssertNil(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby")
        )
    }

    func test_externalApplicationIdentity_returnsNilWhenBundleIdentifierIsMissing() {
        let snapshot = FocusSnapshot(
            applicationName: "Unknown",
            bundleIdentifier: nil,
            capability: .unsupported("No active application."),
            context: nil,
            inspection: nil
        )

        XCTAssertNil(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby")
        )
    }
}

/// Tests for the durable disabled-app blocklist.
///
/// These live beside the evaluator tests because the two pieces form one contract: settings own
/// persistence, while the evaluator consumes the snapshot produced from those settings.
@MainActor
final class SuggestionSettingsModelDisabledAppsTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func test_disabledAppRules_surviveModelRecreation() {
        let userDefaults = makeUserDefaults()
        let model = makeModel(userDefaults: userDefaults)

        model.disableApplication(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari"
        )

        let reloadedModel = makeModel(userDefaults: userDefaults)

        XCTAssertEqual(
            reloadedModel.disabledAppRules,
            [
                DisabledApplicationRule(
                    bundleIdentifier: "com.apple.Safari",
                    displayName: "Safari"
                )
            ]
        )
    }

    func test_disableApplication_reusesBundleIdentifierInsteadOfDuplicating() {
        let model = makeModel()

        model.disableApplication(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari"
        )
        model.disableApplication(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari Technology Preview"
        )

        XCTAssertEqual(model.disabledAppRules.count, 1)
        XCTAssertEqual(model.disabledAppRules.first?.displayName, "Safari Technology Preview")
    }

    func test_removeDisabledApplication_deletesOnlyMatchingBundleIdentifier() {
        let model = makeModel()

        model.disableApplication(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        model.disableApplication(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")
        model.removeDisabledApplication(bundleIdentifier: "com.apple.Safari")

        XCTAssertFalse(model.isApplicationDisabled(bundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(model.isApplicationDisabled(bundleIdentifier: "com.tinyspeck.slackmacgap"))
        XCTAssertEqual(model.disabledAppRules.map(\.bundleIdentifier), ["com.tinyspeck.slackmacgap"])
    }

    func test_snapshotPublisher_emitsWhenDisabledAppRulesChange() {
        let model = makeModel()
        let expectation = expectation(description: "snapshot emits after app rule changes")
        var cancellables = Set<AnyCancellable>()

        model.snapshotPublisher
            .dropFirst()
            .sink { snapshot in
                XCTAssertTrue(snapshot.disabledAppBundleIdentifiers.contains("com.apple.Safari"))
                expectation.fulfill()
            }
            .store(in: &cancellables)

        model.disableApplication(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari"
        )

        wait(for: [expectation], timeout: 1.0)
        _ = cancellables
    }

    private func makeModel(
        userDefaults: UserDefaults? = nil
    ) -> SuggestionSettingsModel {
        SuggestionSettingsModel(
            configuration: .standard,
            userDefaults: userDefaults ?? makeUserDefaults()
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "SuggestionSettingsModelDisabledAppsTests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected an isolated UserDefaults suite")
            return .standard
        }

        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}
