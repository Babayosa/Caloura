import CryptoKit
import Foundation
import os.log

/// Stateless license verifier. Routes a license key through the signed
/// entitlement backend (production) or the Gumroad fallback (DEBUG only),
/// and returns a `LicenseValidationResult`. Extracted from `LicenseManager`
/// so the network/signature decode path can be exercised without driving
/// the activation state machine, settings persistence, or revalidation
/// scheduler that the manager owns.
struct LicenseEntitlementVerifier: Sendable {
    static let gumroadProductID = "bmokl"
    static let gumroadVerifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
    static let revalidationInterval: TimeInterval = 86_400
    static let offlineEntitlementDuration: TimeInterval = 7 * 86_400
    static let maximumResponseBytes = 1_000_000

    let session: URLSession
    let now: @Sendable () -> Date
    let configuration: LicenseVerificationConfiguration
    let logger: Logger

    func verify(
        key: String,
        existingEntitlement: LicenseEntitlement?
    ) async -> LicenseValidationResult {
        if let backendURL = configuration.entitlementServiceURL,
           let publicKey = configuration.entitlementPublicKeyBase64 {
            return await verifyWithSignedBackend(
                key: key,
                backendURL: backendURL,
                publicKeyBase64: publicKey
            )
        }

        if configuration.requiresSignedEntitlement {
            logger.error("Signed entitlement verification required but not configured.")
            return .invalid(reason: "This build requires a configured license entitlement service.")
        }

#if DEBUG
        guard configuration.allowGumroadFallback else {
            return .invalid(reason: "Signed license verification is not available in this build.")
        }
        return await verifyWithGumroadFallback(
            key: key,
            existingEntitlement: existingEntitlement
        )
#else
        return .invalid(reason: "This build requires signed license verification.")
#endif
    }

    private func verifyWithSignedBackend(
        key: String,
        backendURL: URL,
        publicKeyBase64: String
    ) async -> LicenseValidationResult {
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "license_key": key
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.url?.host == backendURL.host,
                  data.count < Self.maximumResponseBytes else {
                return .ambiguousResponse
            }

            guard httpResponse.statusCode == 200 else {
                if (400...499).contains(httpResponse.statusCode) {
                    return .invalid(reason: "Invalid license key.")
                }
                return .ambiguousResponse
            }

            guard let envelope = try? JSONDecoder().decode(
                SignedEntitlementEnvelope.self,
                from: data
            ) else {
                return .ambiguousResponse
            }

            switch Self.decodeSignedEntitlement(
                envelope.token,
                expectedProductID: Self.gumroadProductID,
                publicKeyBase64: publicKeyBase64,
                validatedAt: now()
            ) {
            case .valid(let entitlement):
                return .valid(entitlement)
            case .invalidClaims:
                return .invalid(reason: "Invalid license key.")
            case .malformed, .invalidSignature:
                return .ambiguousResponse
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

#if DEBUG
    private func verifyWithGumroadFallback(
        key: String,
        existingEntitlement: LicenseEntitlement?
    ) async -> LicenseValidationResult {
        var request = URLRequest(url: Self.gumroadVerifyURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "product_id", value: Self.gumroadProductID),
            URLQueryItem(name: "license_key", value: key)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.url?.host == Self.gumroadVerifyURL.host,
                  data.count < Self.maximumResponseBytes else {
                return .ambiguousResponse
            }

            guard httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success else {
                return .invalid(reason: "Invalid license key.")
            }

            if let purchase = json["purchase"] as? [String: Any] {
                if purchase["refunded"] as? Bool == true ||
                    purchase["disputed"] as? Bool == true ||
                    purchase["chargebacked"] as? Bool == true {
                    return .invalid(reason: "This license has been refunded or disputed.")
                }

                let validatedAt = now()
                let fallbackEntitlement = LicenseEntitlement(
                    claims: LicenseEntitlementClaims(
                        productID: Self.gumroadProductID,
                        licenseID: Self.licenseIdentifier(from: purchase, key: key),
                        issuedAt: validatedAt,
                        refreshAfter: validatedAt.addingTimeInterval(Self.revalidationInterval),
                        expiresAt: validatedAt.addingTimeInterval(Self.offlineEntitlementDuration),
                        featureFlags: Self.featureFlags(
                            from: purchase,
                            existingEntitlement: existingEntitlement
                        )
                    ),
                    source: .gumroadFallback,
                    token: nil,
                    signature: nil,
                    validatedAt: validatedAt
                )
                return .valid(fallbackEntitlement)
            }

            return .ambiguousResponse
        } catch {
            return .networkError(error.localizedDescription)
        }
    }
#endif

    private static func licenseIdentifier(from purchase: [String: Any], key: String) -> String {
        if let id = purchase["id"] as? String, !id.isEmpty {
            return id
        }
        return SHA256Hex.encode(key)
    }

    private static func featureFlags(
        from purchase: [String: Any],
        existingEntitlement: LicenseEntitlement?
    ) -> [String: Bool] {
        if let flags = purchase["feature_flags"] as? [String: Bool] {
            return flags
        }
        return existingEntitlement?.claims.featureFlags ?? [:]
    }

    private enum SignedEntitlementDecodeResult {
        case valid(LicenseEntitlement)
        case invalidClaims
        case invalidSignature
        case malformed
    }

    private static func decodeSignedEntitlement(
        _ token: String,
        expectedProductID: String,
        publicKeyBase64: String,
        validatedAt: Date
    ) -> SignedEntitlementDecodeResult {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = base64URLDecode(String(parts[0])),
              let signature = base64URLDecode(String(parts[1])),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let claims = try? JSONDecoder().decode(LicenseEntitlementClaims.self, from: payloadData) else {
            return .malformed
        }

        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return .malformed
        }

        guard publicKey.isValidSignature(signature, for: payloadData) else {
            return .invalidSignature
        }

        guard claims.productID == expectedProductID,
              claims.issuedAt <= claims.refreshAfter,
              claims.refreshAfter <= claims.expiresAt,
              claims.expiresAt > validatedAt else {
            return .invalidClaims
        }

        return .valid(LicenseEntitlement(
            claims: claims,
            source: .signedBackend,
            token: token,
            signature: signature,
            validatedAt: validatedAt
        ))
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = normalized.count % 4
        if padding != 0 {
            normalized += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: normalized)
    }
}

private struct SignedEntitlementEnvelope: Decodable {
    let token: String
}
