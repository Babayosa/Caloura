import CryptoKit
import Foundation

enum HistoryCryptoError: Error {
    case missingCombinedBox
    case keychainWriteFailed
}

enum HistoryCrypto {
    private static let keyAccount = "screenshotHistoryKey"
    private static let keyService = Bundle.main.bundleIdentifier ?? "com.caloura.app"
    private static var cachedKey: SymmetricKey?

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
        if let cachedKey {
            return cachedKey
        }

        if let stored = KeychainHelper.getData(service: keyService, account: keyAccount) {
            let key = SymmetricKey(data: stored)
            cachedKey = key
            return key
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        guard KeychainHelper.setData(keyData, service: keyService, account: keyAccount) else {
            throw HistoryCryptoError.keychainWriteFailed
        }
        cachedKey = key
        return key
    }
}
