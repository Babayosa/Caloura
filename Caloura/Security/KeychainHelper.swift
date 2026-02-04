import Foundation
import LocalAuthentication
import Security

enum LegacyKeychainReadResult {
    case success(String)
    case notFound
    case interactionRequired
    case failure(OSStatus)
}

/// Deprecated runtime helper.
/// New runtime persistence must not depend on Keychain; this helper exists only
/// for best-effort, non-interactive migration of legacy values.
enum KeychainHelper {
    static func readLegacyStringNonInteractive(service: String, account: String) -> LegacyKeychainReadResult {
        let authContext = LAContext()
        authContext.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authContext
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                return .failure(errSecDecode)
            }
            return .success(value)
        case errSecItemNotFound:
            return .notFound
        case _ where isInteractionRequiredStatus(status):
            return .interactionRequired
        default:
            return .failure(status)
        }
    }

    static func deleteLegacyItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func isInteractionRequiredStatus(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed ||
        status == errSecUserCanceled ||
        status == errSecAuthFailed
    }
}
