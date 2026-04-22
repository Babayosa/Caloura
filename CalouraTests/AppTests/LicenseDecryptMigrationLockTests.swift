import Foundation
import XCTest
@testable import Caloura

@MainActor
final class LicenseDecryptMigrationLockTests: XCTestCase {

    private var defaultsName: String = ""
    private var tempCryptoRoot: URL?

    override func setUp() {
        super.setUp()
        defaultsName = "com.caloura.tests.licenseLock.\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("license-lock-\(UUID().uuidString)", isDirectory: true)
        tempCryptoRoot = dir
        HistoryCrypto.setSecurityDirectoryForTesting(dir.appendingPathComponent("security"))
        HistoryCrypto.resetCachedKeyForTesting()
    }

    override func tearDown() {
        if let dir = tempCryptoRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        HistoryCrypto.setSecurityDirectoryForTesting(nil)
        HistoryCrypto.resetCachedKeyForTesting()
        super.tearDown()
    }

    // MARK: - decryptLicenseKey

    func testDecryptRejectsPlaintextWhenMigrationLocked() {
        // Once the lock is set, plaintext input must NEVER be returned. This
        // protects against UserDefaults tampering or a downgrade attack that
        // tries to roll back the encrypted key by replacing it with a forged
        // plaintext string.
        let plaintext: Any = "FORGED-LICENSE-KEY-1234"
        let result = AppSettings.decryptLicenseKey(
            plaintext,
            migrated: false,
            migrationLocked: true
        )
        XCTAssertNil(result, "plaintext must be rejected when migrationLocked == true")
    }

    func testDecryptRejectsPlaintextWhenMigratedFlagSet() {
        // Pre-lock behavior preserved: even without the lock, once migration
        // has happened, plaintext is no longer trusted.
        let plaintext: Any = "PLAINTEXT-KEY"
        let result = AppSettings.decryptLicenseKey(
            plaintext,
            migrated: true,
            migrationLocked: false
        )
        XCTAssertNil(result)
    }

    func testDecryptAcceptsPlaintextDuringLegacyMigration() {
        // 2.3.x → 2.5.0 path: existing user has a plaintext key in UserDefaults,
        // both flags false. Decrypt accepts once so the key gets re-encrypted
        // by the subsequent persist; the lock then closes the door behind it.
        let plaintext: Any = "LEGACY-PLAINTEXT-KEY"
        let result = AppSettings.decryptLicenseKey(
            plaintext,
            migrated: false,
            migrationLocked: false
        )
        XCTAssertEqual(result, "LEGACY-PLAINTEXT-KEY")
    }

    func testDecryptReturnsNilForUnreadableData() {
        let garbage: Any = Data([0xFF, 0x00, 0x42, 0x13])
        let result = AppSettings.decryptLicenseKey(
            garbage,
            migrated: true,
            migrationLocked: true
        )
        XCTAssertNil(result)
    }

    func testDecryptRoundTripsValidEncryptedBlob() throws {
        let originalKey = "VALID-LICENSE-KEY-9999"
        let encrypted = AppSettings.encryptLicenseKey(originalKey)
        XCTAssertNotNil(encrypted, "test setup: encrypt must succeed")

        let result = AppSettings.decryptLicenseKey(
            encrypted as Any,
            migrated: true,
            migrationLocked: true
        )
        XCTAssertEqual(result, originalKey, "encrypted blob must always decrypt regardless of lock state")
    }

    // MARK: - Lock activation

    func testFreshInstallSetsMigrationLockOnFirstActivation() {
        // No keyBlob, no entitlement, no legacy activation flag → fresh install.
        // The lock must be set immediately so a future plaintext write cannot
        // be honored.
        let defaults = UserDefaults(suiteName: defaultsName)!
        XCTAssertFalse(defaults.bool(forKey: "licenseKeyMigrationLocked"))

        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: { .notFound }
        )
        _ = settings  // keep alive across activate

        XCTAssertTrue(
            defaults.bool(forKey: "licenseKeyMigrationLocked"),
            "fresh install must lock plaintext acceptance immediately at first launch"
        )
    }

    func testEncryptedPersistSetsMigrationLock() {
        let defaults = UserDefaults(suiteName: defaultsName)!
        let settings = AppSettings(
            defaults: defaults,
            legacyLicenseMigration: { .notFound }
        )

        // Even after fresh-install lock, persisting an actual key must keep
        // the lock set. Setting the licenseKey property triggers persist.
        settings.licenseKey = "REAL-LICENSE-KEY"

        XCTAssertTrue(defaults.bool(forKey: "licenseKeyMigrationLocked"))
        XCTAssertTrue(defaults.bool(forKey: "licenseKeyMigrated"))
        XCTAssertNotNil(defaults.object(forKey: "licenseKey"), "key blob must be persisted")
        XCTAssertTrue(
            defaults.object(forKey: "licenseKey") is Data,
            "persisted key must be encrypted Data, not plaintext String"
        )
    }
}
