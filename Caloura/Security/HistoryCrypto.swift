import CryptoKit
import Foundation

enum HistoryCryptoError: Error {
    case missingCombinedBox
    case keyStorageUnavailable(String)
    case invalidKeyMaterial
    case keyReadFailed(String)
    case keyWriteFailed(String)
}

enum HistoryCrypto {
    private static let keyFileName = "history.key"
    private static let keyQueue = DispatchQueue(label: "com.caloura.historycrypto.key")
    private static var cachedKey: SymmetricKey?
    private static var securityDirectoryOverride: URL?

    static func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw HistoryCryptoError.missingCombinedBox
        }
        return combined
    }

    static func decrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        let sealed = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealed, using: key)
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

            do {
                let securityDir = keyFile.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: securityDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try keyData.write(to: keyFile, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
                cachedKey = key
                return key
            } catch {
                throw HistoryCryptoError.keyWriteFailed(error.localizedDescription)
            }
        }
    }

    private static func keyFileURL() throws -> URL {
        let baseDir = try securityDirectoryURL()
        return baseDir.appendingPathComponent(keyFileName)
    }

    private static func securityDirectoryURL() throws -> URL {
        let baseDir: URL
        if let override = securityDirectoryOverride {
            baseDir = override
        } else if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            baseDir = appSupport.appendingPathComponent("Caloura").appendingPathComponent("security")
        } else {
            throw HistoryCryptoError.keyStorageUnavailable("Could not resolve Application Support directory.")
        }
        return baseDir
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

    static func resetCachedKeyForTesting() {
        keyQueue.sync { cachedKey = nil }
    }

    static func setSecurityDirectoryForTesting(_ url: URL?) {
        securityDirectoryOverride = url
        keyQueue.sync { cachedKey = nil }
    }
}
