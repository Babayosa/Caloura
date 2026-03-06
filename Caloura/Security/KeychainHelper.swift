import Foundation
import LocalAuthentication
import Security

enum KeychainDataReadResult {
    case success(Data)
    case notFound
    case interactionRequired
    case failure(OSStatus)
}

enum KeychainHelperError: Error {
    case interactionRequired
    case operationFailed(OSStatus)
}

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
    static func readDataNonInteractive(service: String, account: String) -> KeychainDataReadResult {
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
            guard let data = item as? Data else {
                return .failure(errSecDecode)
            }
            return .success(data)
        case errSecItemNotFound:
            return .notFound
        case _ where isInteractionRequiredStatus(status):
            return .interactionRequired
        default:
            return .failure(status)
        }
    }

    static func writeData(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let addQuery = baseQuery.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]) { _, newValue in newValue }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw error(for: updateStatus)
            }
        default:
            throw error(for: addStatus)
        }
    }

    static func readLegacyStringNonInteractive(service: String, account: String) -> LegacyKeychainReadResult {
        switch readDataNonInteractive(service: service, account: account) {
        case .success(let data):
            guard
                let value = String(data: data, encoding: .utf8)
            else {
                return .failure(errSecDecode)
            }
            return .success(value)
        case .notFound:
            return .notFound
        case .interactionRequired:
            return .interactionRequired
        case .failure(let status):
            return .failure(status)
        }
    }

    static func deleteLegacyItem(service: String, account: String) {
        deleteItem(service: service, account: account)
    }

    static func deleteItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func error(for status: OSStatus) -> KeychainHelperError {
        if isInteractionRequiredStatus(status) {
            return .interactionRequired
        }
        return .operationFailed(status)
    }

    static func isInteractionRequiredStatus(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed ||
        status == errSecUserCanceled ||
        status == errSecAuthFailed
    }
}
