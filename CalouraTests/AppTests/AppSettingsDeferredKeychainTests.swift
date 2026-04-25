import Foundation
import XCTest
@testable import Caloura

@MainActor
final class AppSettingsDeferredKeychainTests: XCTestCase {
    private final class MigrationCounter: @unchecked Sendable {
        var value = 0
    }

    private func makeDefaults(_ testName: String) -> UserDefaults {
        let suite = "com.caloura.tests.settings.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSilentlyMigratesLegacyKeyWhenNoLocalKeyExists() async {
        let defaults = makeDefaults(#function)

        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: { .success("LEGACY-KEY-1234") }
        )
        await settings.waitForLegacyLicenseMigrationForTesting()

        XCTAssertEqual(settings.licenseKey, "LEGACY-KEY-1234")
        XCTAssertFalse(settings.isLicenseActivated)
        // License key is now stored encrypted (as Data), not as a plaintext String
        XCTAssertNotNil(defaults.object(forKey: "licenseKey"), "License key should be persisted")
        XCTAssertEqual(defaults.bool(forKey: "isLicenseActivated"), false)
    }

    func testLocalDefaultsActivationFlagDoesNotCreateEntitlement() async {
        let defaults = makeDefaults(#function)
        defaults.set("LOCAL-KEY-9999", forKey: "licenseKey")
        defaults.set(true, forKey: "isLicenseActivated")

        let migrationCounter = MigrationCounter()
        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: {
                migrationCounter.value += 1
                return .success("LEGACY-KEY-1234")
            }
        )
        await settings.waitForLegacyLicenseMigrationForTesting()

        XCTAssertEqual(settings.licenseKey, "LOCAL-KEY-9999")
        XCTAssertFalse(settings.isLicenseActivated)
        XCTAssertNil(settings.currentLicenseEntitlement)
        XCTAssertEqual(migrationCounter.value, 0)
    }

    func testMigrationAttemptFlagPreventsRepeatedLegacyReads() async {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: "hasAttemptedLegacyLicenseMigration")

        let migrationCounter = MigrationCounter()
        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: {
                migrationCounter.value += 1
                return .success("LEGACY-KEY-1234")
            }
        )
        await settings.waitForLegacyLicenseMigrationForTesting()

        XCTAssertTrue(settings.licenseKey.isEmpty)
        XCTAssertEqual(migrationCounter.value, 0)
    }
}
