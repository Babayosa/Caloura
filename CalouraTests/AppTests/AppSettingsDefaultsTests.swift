import Foundation
import XCTest
@testable import Caloura

/// Locks in the fresh-install defaults for privacy/history settings so a future
/// refactor can't silently regress them. Uses an isolated defaults suite and a
/// no-op legacy-license migration to avoid touching the real keychain.
@MainActor
final class AppSettingsDefaultsTests: XCTestCase {
    private func makeFreshSettings(_ testName: String) -> AppSettings {
        let suite = "com.caloura.tests.settings.defaults.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, legacyLicenseMigration: { .notFound })
    }

    func testAutoDetectPII_defaultsOnForFreshInstall() {
        let settings = makeFreshSettings(#function)
        XCTAssertTrue(
            settings.autoDetectPII,
            "PII detection must default ON so sensitive captures are surfaced for review"
        )
    }

    func testHistoryItemLimit_defaultsTo200ForFreshInstall() {
        let settings = makeFreshSettings(#function)
        XCTAssertEqual(settings.historyItemLimit, 200)
    }

    func testExplicitUserChoiceOverridesDefaults() {
        let suite = "com.caloura.tests.settings.defaults.\(#function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Simulate a user who explicitly turned PII detection off and shrank history.
        defaults.set(false, forKey: AppSettings.Keys.autoDetectPII)
        defaults.set(50, forKey: AppSettings.Keys.historyItemLimit)

        let settings = AppSettings(defaults: defaults, legacyLicenseMigration: { .notFound })

        XCTAssertFalse(settings.autoDetectPII, "Stored user choice must win over the new default")
        XCTAssertEqual(settings.historyItemLimit, 50)
    }
}
