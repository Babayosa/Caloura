import Foundation
import XCTest
@testable import Caloura

@MainActor
final class AppSettingsDeferredKeychainTests: XCTestCase {

    private func makeDefaults(_ testName: String) -> UserDefaults {
        let suite = "com.caloura.tests.settings.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSilentlyMigratesLegacyKeyWhenNoLocalKeyExists() {
        let defaults = makeDefaults(#function)

        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: { .success("LEGACY-KEY-1234") }
        )

        XCTAssertEqual(settings.licenseKey, "LEGACY-KEY-1234")
        XCTAssertFalse(settings.isLicenseActivated)
        // License key is now stored encrypted (as Data), not as a plaintext String
        XCTAssertNotNil(defaults.object(forKey: "licenseKey"), "License key should be persisted")
        XCTAssertEqual(defaults.bool(forKey: "isLicenseActivated"), false)
    }

    func testSkipsMigrationWhenLocalKeyAlreadyExists() {
        let defaults = makeDefaults(#function)
        defaults.set("LOCAL-KEY-9999", forKey: "licenseKey")
        defaults.set(true, forKey: "isLicenseActivated")

        var migrationCalls = 0
        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: {
                migrationCalls += 1
                return .success("LEGACY-KEY-1234")
            }
        )

        XCTAssertEqual(settings.licenseKey, "LOCAL-KEY-9999")
        XCTAssertTrue(settings.isLicenseActivated)
        XCTAssertEqual(migrationCalls, 0)
    }

    func testMigrationAttemptFlagPreventsRepeatedLegacyReads() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: "hasAttemptedLegacyLicenseMigration")

        var migrationCalls = 0
        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: {
                migrationCalls += 1
                return .success("LEGACY-KEY-1234")
            }
        )

        XCTAssertTrue(settings.licenseKey.isEmpty)
        XCTAssertEqual(migrationCalls, 0)
    }
}
