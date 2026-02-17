import CryptoKit
import Foundation

// MARK: - Threat Model
//
// HistoryCrypto encrypts history data at rest using AES-256-GCM.
//
// Key storage: a 256-bit root key is stored as a local file at
// ~/Library/Application Support/Caloura/security/history.key with POSIX 0600
// permissions (directory: 0700).
//
// Protects against: other users on the same machine reading history data,
// and casual inspection of the Application Support directory.
//
// Does NOT protect against: malware running as the same user, or physical
// access to an unlocked machine (the key file is readable by the current user).
//
// Why not Keychain: project convention avoids Keychain to prevent startup
// authentication prompts that degrade the user experience.
//
// HKDF key derivation: different purposes (e.g. "history-encryption") derive
// distinct subkeys from the single root key, enabling domain separation.

enum HistoryCryptoError: Error {
    case missingCombinedBox
    case keyStorageUnavailable(String)
    case invalidKeyMaterial
    case keyReadFailed(String)
    case keyWriteFailed(String)
    case keyFileCreationFailed
}

enum HistoryCrypto {
    private static let keyFileName = "history.key"
    private static let keyQueue = DispatchQueue(label: "com.caloura.historycrypto.key")
    private static var cachedKey: SymmetricKey?
    #if DEBUG
    private static var securityDirectoryOverride: URL?
    #endif
    private static let currentKeyVersion: UInt8 = 1
    // AES-GCM nonce (12) + tag (16) = 28 bytes minimum for a valid sealed box
    private static let minimumSealedBoxLength = 28

    static func encrypt(_ data: Data, purpose: String = "history-encryption") throws -> Data {
        let rootKey = try getOrCreateKey()
        let derivedKey = deriveKey(rootKey: rootKey, purpose: purpose)
        let sealed = try AES.GCM.seal(data, using: derivedKey)
        guard let combined = sealed.combined else {
            throw HistoryCryptoError.missingCombinedBox
        }
        return Data([currentKeyVersion]) + combined
    }

    static func decrypt(_ data: Data, purpose: String = "history-encryption") throws -> Data {
        let rootKey = try getOrCreateKey()
        let derivedKey = deriveKey(rootKey: rootKey, purpose: purpose)

        // Try versioned format: first byte is a known version, rest is sealed box
        if let firstByte = data.first,
           firstByte == currentKeyVersion,
           data.count >= 1 + minimumSealedBoxLength {
            do {
                let sealedData = data.dropFirst()
                let sealed = try AES.GCM.SealedBox(combined: sealedData)
                return try AES.GCM.open(sealed, using: derivedKey)
            } catch {
                // First byte coincidentally matched version — fall through to legacy
            }
        }

        // Legacy format (no version prefix, no HKDF): try derived key first,
        // then fall back to raw master key for pre-HKDF data
        let sealed = try AES.GCM.SealedBox(combined: data)
        do {
            return try AES.GCM.open(sealed, using: derivedKey)
        } catch {
            return try AES.GCM.open(sealed, using: rootKey)
        }
    }

    private static func deriveKey(rootKey: SymmetricKey, purpose: String) -> SymmetricKey {
        let info = Data(purpose.utf8)
        return SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rootKey,
            info: info,
            outputByteCount: 32
        ))
    }

    private static func getOrCreateKey() throws -> SymmetricKey {
        try keyQueue.sync {
            if let cachedKey {
                return cachedKey
            }

            let keyFile = try keyFileURL()
            let fileManager = FileManager.default

            if fileManager.fileExists(atPath: keyFile.path) {
                do {
                    let stored = try Data(contentsOf: keyFile)
                    guard stored.count == 32 else {
                        throw HistoryCryptoError.invalidKeyMaterial
                    }
                    let key = SymmetricKey(data: stored)
                    cachedKey = key
                    return key
                } catch let error as HistoryCryptoError {
                    throw error
                } catch {
                    throw HistoryCryptoError.keyReadFailed(error.localizedDescription)
                }
            }

            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }

            let securityDir = keyFile.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: securityDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            // Atomic create-if-not-exists to prevent TOCTOU race
            let fd = open(keyFile.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else {
                if errno == EEXIST {
                    // Another process created the file between our exists-check and here
                    let stored = try Data(contentsOf: keyFile)
                    guard stored.count == 32 else { throw HistoryCryptoError.invalidKeyMaterial }
                    let existingKey = SymmetricKey(data: stored)
                    cachedKey = existingKey
                    return existingKey
                }
                throw HistoryCryptoError.keyFileCreationFailed
            }
            let written = keyData.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }
            close(fd)
            guard written == keyData.count else {
                try? fileManager.removeItem(at: keyFile)
                throw HistoryCryptoError.keyWriteFailed("Partial write: \(written)/\(keyData.count)")
            }
            cachedKey = key
            return key
        }
    }

    private static func keyFileURL() throws -> URL {
        let baseDir = try securityDirectoryURL()
        return baseDir.appendingPathComponent(keyFileName)
    }

    private static func securityDirectoryURL() throws -> URL {
        #if DEBUG
        if let override = securityDirectoryOverride {
            return override
        }
        #endif
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw HistoryCryptoError.keyStorageUnavailable("Could not resolve Application Support directory.")
        }
        return appSupport.appendingPathComponent("Caloura").appendingPathComponent("security")
    }

    // MARK: - Secure File I/O

    static func applicationSupportURL(filename: String) -> URL {
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Caloura/\(filename)")
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return fallback }
        return appSupport.appendingPathComponent("Caloura").appendingPathComponent(filename)
    }

    static func writeEncrypted(
        _ data: Data,
        to url: URL,
        purpose: String = "history-encryption"
    ) throws {
        let encrypted = try encrypt(data, purpose: purpose)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encrypted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func readEncrypted(from url: URL, purpose: String = "history-encryption") throws -> Data {
        let encrypted = try Data(contentsOf: url)
        return try decrypt(encrypted, purpose: purpose)
    }

    static func auditStoragePermissions(historyFileURL: URL) -> [String] {
        var warnings: [String] = []
        let fileManager = FileManager.default

        do {
            let securityDirectory = try securityDirectoryURL()
            if fileManager.fileExists(atPath: securityDirectory.path) {
                appendPermissionWarningIfNeeded(
                    for: securityDirectory,
                    expected: 0o700,
                    label: "History security directory",
                    to: &warnings
                )
            }

            let keyFile = securityDirectory.appendingPathComponent(keyFileName)
            if fileManager.fileExists(atPath: keyFile.path) {
                appendPermissionWarningIfNeeded(
                    for: keyFile,
                    expected: 0o600,
                    label: "History encryption key file",
                    to: &warnings
                )
            }
        } catch {
            warnings.append("History security permission audit skipped: \(error.localizedDescription)")
        }

        if fileManager.fileExists(atPath: historyFileURL.path) {
            appendPermissionWarningIfNeeded(
                for: historyFileURL,
                expected: 0o600,
                label: "History encrypted payload file",
                to: &warnings
            )
        }

        return warnings
    }

    private static func appendPermissionWarningIfNeeded(
        for url: URL,
        expected: Int,
        label: String,
        to warnings: inout [String]
    ) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let mode = attributes[.posixPermissions] as? NSNumber else {
                warnings.append("\(label) has no POSIX mode metadata: \(url.path)")
                return
            }
            let actual = mode.intValue
            guard actual != expected else { return }
            let expectedStr = octalString(expected)
            let actualStr = octalString(actual)
            warnings.append(
                "\(label) permission drift (\(url.path)): "
                + "expected \(expectedStr), got \(actualStr)"
            )
        } catch {
            warnings.append("Could not read permissions for \(label) at \(url.path): \(error.localizedDescription)")
        }
    }

    private static func octalString(_ value: Int) -> String {
        String(format: "0%o", value)
    }

    // MARK: - Testing Helpers

    #if DEBUG
    static func resetCachedKeyForTesting() {
        keyQueue.sync { cachedKey = nil }
    }

    static func setSecurityDirectoryForTesting(_ url: URL?) {
        securityDirectoryOverride = url
        keyQueue.sync { cachedKey = nil }
    }
    #endif
}
