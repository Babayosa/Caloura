import CryptoKit
import XCTest
@testable import Caloura

final class HistoryCryptoTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalouraHistoryCryptoTest_\(UUID().uuidString)")
        HistoryCrypto.setSecurityDirectoryForTesting(tempDir)
    }

    override func tearDown() {
        HistoryCrypto.setSecurityDirectoryForTesting(nil)
        HistoryCrypto.resetCachedKeyForTesting()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Round-Trip

    func testEncryptDecrypt_roundTrip() throws {
        let plaintext = Data("Hello, Caloura!".utf8)
        let encrypted = try HistoryCrypto.encrypt(plaintext)
        let decrypted = try HistoryCrypto.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptDecrypt_emptyData() throws {
        let plaintext = Data()
        let encrypted = try HistoryCrypto.encrypt(plaintext)
        let decrypted = try HistoryCrypto.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptDecrypt_largeData() throws {
        let plaintext = Data(repeating: 0xAB, count: 100_000)
        let encrypted = try HistoryCrypto.encrypt(plaintext)
        let decrypted = try HistoryCrypto.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - Corrupted Ciphertext

    func testDecrypt_corruptedCiphertext_throws() throws {
        let plaintext = Data("secret data".utf8)
        var encrypted = try HistoryCrypto.encrypt(plaintext)

        // Flip a byte in the middle of the ciphertext (past the version byte)
        let midpoint = encrypted.count / 2
        encrypted[midpoint] ^= 0xFF

        XCTAssertThrowsError(try HistoryCrypto.decrypt(encrypted))
    }

    // MARK: - Truncated Data

    func testDecrypt_truncatedData_throws() {
        // Too short to be a valid AES-GCM sealed box (nonce=12 + tag=16 = 28 min)
        let truncated = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertThrowsError(try HistoryCrypto.decrypt(truncated))
    }

    func testDecrypt_versionByteOnly_throws() {
        // Just the version byte, no sealed box data
        let data = Data([0x01])
        XCTAssertThrowsError(try HistoryCrypto.decrypt(data))
    }

    // MARK: - Key File Auto-Creation

    func testKeyFileAutoCreation() throws {
        let keyFile = tempDir.appendingPathComponent("history.key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))

        // Triggering encrypt forces key creation
        _ = try HistoryCrypto.encrypt(Data("trigger".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFile.path))

        // Key file should be exactly 32 bytes (256-bit key)
        let keyData = try Data(contentsOf: keyFile)
        XCTAssertEqual(keyData.count, 32)
    }

    func testKeyFilePersistence_acrossResets() throws {
        let plaintext = Data("persistent check".utf8)
        let encrypted = try HistoryCrypto.encrypt(plaintext)

        // Reset cached key — forces re-read from disk
        HistoryCrypto.resetCachedKeyForTesting()

        let decrypted = try HistoryCrypto.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - HKDF Purpose Separation

    func testDifferentPurposes_produceDifferentCiphertexts() throws {
        let plaintext = Data("same data".utf8)
        let encrypted1 = try HistoryCrypto.encrypt(plaintext, purpose: "purpose-a")
        let encrypted2 = try HistoryCrypto.encrypt(plaintext, purpose: "purpose-b")

        // Different purposes should produce different ciphertext
        // (Different derived keys + different random nonces)
        XCTAssertNotEqual(encrypted1, encrypted2)
    }

    func testDifferentPurposes_cannotCrossDecrypt() throws {
        let plaintext = Data("isolated data".utf8)
        let encrypted = try HistoryCrypto.encrypt(plaintext, purpose: "purpose-a")

        // Decrypting with a different purpose should fail
        XCTAssertThrowsError(try HistoryCrypto.decrypt(encrypted, purpose: "purpose-b"))
    }

    func testSamePurpose_roundTrips() throws {
        let plaintext = Data("custom purpose".utf8)
        let purpose = "custom-purpose-key"
        let encrypted = try HistoryCrypto.encrypt(plaintext, purpose: purpose)
        let decrypted = try HistoryCrypto.decrypt(encrypted, purpose: purpose)
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - Version Byte

    func testEncrypt_prependsVersionByte() throws {
        let encrypted = try HistoryCrypto.encrypt(Data("test".utf8))
        XCTAssertEqual(encrypted.first, 0x01, "First byte should be version 0x01")
    }

    func testEncrypt_versionedFormat_hasMinimumLength() throws {
        let encrypted = try HistoryCrypto.encrypt(Data("test".utf8))
        // Version byte (1) + nonce (12) + ciphertext (>=1 for "test") + tag (16) = >=30
        XCTAssertGreaterThanOrEqual(encrypted.count, 1 + 28)
    }

    // MARK: - Legacy Format (No Version Prefix)

    func testLegacyFormat_rawRootKey_decrypts() throws {
        // Simulate legacy format: encrypt directly with the raw root key, no version prefix.
        // First, trigger key creation so we can read it.
        _ = try HistoryCrypto.encrypt(Data("init".utf8))

        let keyFile = tempDir.appendingPathComponent("history.key")
        let keyData = try Data(contentsOf: keyFile)
        let rawKey = SymmetricKey(data: keyData)

        // Encrypt with raw key (legacy format: no HKDF, no version prefix)
        let plaintext = Data("legacy secret".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: rawKey)
        let legacyCiphertext = sealed.combined!

        // Reset cache to ensure fresh key load
        HistoryCrypto.resetCachedKeyForTesting()

        // Decrypt should succeed via the legacy fallback path
        let decrypted = try HistoryCrypto.decrypt(legacyCiphertext)
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - Security Directory Permissions

    func testSecurityDirectory_createdWith0700() throws {
        // Trigger key creation which creates the directory
        _ = try HistoryCrypto.encrypt(Data("trigger".utf8))

        let attrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
    }

    func testKeyFile_createdWith0600() throws {
        _ = try HistoryCrypto.encrypt(Data("trigger".utf8))

        let keyFile = tempDir.appendingPathComponent("history.key")
        let attrs = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
