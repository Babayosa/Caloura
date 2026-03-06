import CryptoKit
import Foundation
import os.log

enum LicenseEntitlementSource: String, Codable, Equatable {
    case signedBackend
    case gumroadFallback
    case legacyMigration
}

struct LicenseEntitlementClaims: Codable, Equatable {
    let productID: String
    let licenseID: String
    let issuedAt: Date
    let refreshAfter: Date
    let expiresAt: Date
    let featureFlags: [String: Bool]
}

struct LicenseEntitlement: Codable, Equatable {
    let claims: LicenseEntitlementClaims
    let source: LicenseEntitlementSource
    let token: String?
    let signature: Data?
    let validatedAt: Date

    func isCurrentlyValid(at date: Date) -> Bool {
        claims.expiresAt > date
    }
}

enum LicenseState: Equatable {
    case trial(daysRemaining: Int)
    case expired
    case licensed(LicenseEntitlement)
}

enum LicenseValidationResult {
    case valid(LicenseEntitlement)
    case invalid(reason: String)
    case ambiguousResponse
    case networkError(String)
}

enum ActivationState: Equatable {
    case checking
    case trial(daysRemaining: Int)
    case expired
    case licensed
    case activationFailed(String)
}

struct LicenseVerificationConfiguration: Equatable {
    let entitlementServiceURL: URL?
    let entitlementPublicKeyBase64: String?
    let requiresSignedEntitlement: Bool
    let allowGumroadFallback: Bool

    static func bundleDefault(bundle: Bundle = .main) -> LicenseVerificationConfiguration {
        let configuredRequiresSigned = normalizedBool(
            bundle.object(forInfoDictionaryKey: "CalouraRequireSignedEntitlement")
        )
#if DEBUG
        let requiresSigned = configuredRequiresSigned
        let allowFallback = !configuredRequiresSigned
#else
        let requiresSigned = true
        let allowFallback = false
#endif

        return LicenseVerificationConfiguration(
            entitlementServiceURL: normalizedURL(
                bundle.object(forInfoDictionaryKey: "CalouraLicenseEntitlementURL") as? String
            ),
            entitlementPublicKeyBase64: normalizedString(
                bundle.object(forInfoDictionaryKey: "CalouraLicenseEntitlementPublicKey") as? String
            ),
            requiresSignedEntitlement: requiresSigned,
            allowGumroadFallback: allowFallback
        )
    }

    private static func normalizedURL(_ rawValue: String?) -> URL? {
        guard let normalized = normalizedString(rawValue) else {
            return nil
        }
        return URL(string: normalized)
    }

    private static func normalizedString(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedBool(_ rawValue: Any?) -> Bool {
        if let boolValue = rawValue as? Bool {
            return boolValue
        }
        guard let stringValue = rawValue as? String else {
            return false
        }
        switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
}

@MainActor
final class LicenseManager: ObservableObject {
    private static let gumroadProductID = "bmokl"
    private static let gumroadVerifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
    static let gumroadPurchaseURL = URL(string: "https://babayosa.gumroad.com/l/bmokl")!
    static let trialDurationDays = 7
    private static let revalidationInterval: TimeInterval = 86_400
    private static let offlineEntitlementDuration: TimeInterval = 7 * 86_400
    private static let maximumResponseBytes = 1_000_000

    private let logger = Logger(subsystem: "com.caloura.app", category: "License")
    private let session: URLSession
    private let now: () -> Date
    private let verificationConfiguration: LicenseVerificationConfiguration

    @Published private(set) var activationState: ActivationState = .checking

    private var revalidationTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        verificationConfiguration: LicenseVerificationConfiguration = .bundleDefault()
    ) {
        self.session = session
        self.now = now
        self.verificationConfiguration = verificationConfiguration
        refreshState(settings: settings)
    }

    func trialDaysRemaining(settings: AppSettings) -> Int {
        let now = now()
        let effectiveNow = max(now, settings.furthestDateSeen ?? now)
        if now >= (settings.furthestDateSeen ?? .distantPast) {
            settings.furthestDateSeen = now
        }
        let elapsed = Calendar.current.dateComponents(
            [.day],
            from: settings.firstLaunchDate,
            to: effectiveNow
        ).day ?? 0
        let normalizedElapsed = max(0, elapsed)
        return max(0, min(Self.trialDurationDays, Self.trialDurationDays - normalizedElapsed))
    }

    func isTrialExpired(settings: AppSettings) -> Bool {
        if settings.isLicenseActivated { return false }
        return trialDaysRemaining(settings: settings) == 0
    }

    func shouldShowNag(settings: AppSettings) -> Bool {
        isTrialExpired(settings: settings) && !settings.isLicenseActivated
    }

    func refreshState(settings: AppSettings) {
        let state = currentLicenseState(settings: settings)
        activationState = activationState(for: state)
        scheduleRevalidationIfNeeded(settings: settings)
    }

    func activate(licenseKey: String, settings: AppSettings) async {
        let normalizedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            activationState = .activationFailed("Enter a license key.")
            return
        }

        activationState = .checking

        switch await verifyLicense(key: normalizedKey, existingEntitlement: settings.currentLicenseEntitlement) {
        case .valid(let entitlement):
            settings.licenseKey = normalizedKey
            settings.updateLicenseEntitlement(entitlement)
            activationState = .licensed
            scheduleRevalidationIfNeeded(settings: settings)
            logger.info("License activated successfully.")
        case .invalid(let reason):
            settings.updateLicenseEntitlement(nil)
            activationState = .activationFailed(reason)
        case .ambiguousResponse:
            activationState = .activationFailed("Unexpected response from server.")
        case .networkError:
            activationState = .activationFailed(
                "Network error. Please check your connection and try again."
            )
        }
    }

    private func currentLicenseState(settings: AppSettings) -> LicenseState {
        let now = now()
        if let entitlement = settings.currentLicenseEntitlement,
           entitlement.isCurrentlyValid(at: now) {
            return .licensed(entitlement)
        }

        if isTrialExpired(settings: settings) {
            return .expired
        }

        return .trial(daysRemaining: trialDaysRemaining(settings: settings))
    }

    private func activationState(for state: LicenseState) -> ActivationState {
        switch state {
        case .trial(let daysRemaining):
            return .trial(daysRemaining: daysRemaining)
        case .expired:
            return .expired
        case .licensed:
            return .licensed
        }
    }

    private func scheduleRevalidationIfNeeded(settings: AppSettings) {
        revalidationTask?.cancel()

        let key = settings.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            if settings.currentLicenseEntitlement != nil {
                logger.info("License key empty but entitlement present — revoking.")
                settings.updateLicenseEntitlement(nil)
                activationState = activationState(for: currentLicenseState(settings: settings))
            }
            return
        }

        let now = now()
        guard let entitlement = settings.currentLicenseEntitlement else { return }

        if !entitlement.isCurrentlyValid(at: now) {
            scheduleRevalidation(key: key, settings: settings)
            return
        }

        let nextRefreshAt = entitlement.claims.refreshAfter
        guard nextRefreshAt > now else {
            scheduleRevalidation(key: key, settings: settings)
            return
        }

        revalidationTask = Task { [weak self] in
            let delay = nextRefreshAt.timeIntervalSince(now)
            guard delay > 0 else {
                await self?.revalidateLicense(key: key, settings: settings)
                return
            }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.revalidateLicense(key: key, settings: settings)
        }
    }

    private func scheduleRevalidation(key: String, settings: AppSettings) {
        revalidationTask = Task { [weak self] in
            await self?.revalidateLicense(key: key, settings: settings)
        }
    }

    private func revalidateLicense(key: String, settings: AppSettings) async {
        let existingEntitlement = settings.currentLicenseEntitlement

        switch await verifyLicense(key: key, existingEntitlement: existingEntitlement) {
        case .valid(let entitlement):
            settings.updateLicenseEntitlement(entitlement)
            activationState = .licensed
            scheduleRevalidationIfNeeded(settings: settings)
            logger.info("License re-validation succeeded.")
        case .invalid:
            logger.info("License re-validation failed. Revoking activation.")
            settings.updateLicenseEntitlement(nil)
            refreshState(settings: settings)
        case .ambiguousResponse:
            handleDeferredRevalidationFailure(
                key: key,
                settings: settings,
                reason: "ambiguous response"
            )
        case .networkError(let description):
            handleDeferredRevalidationFailure(
                key: key,
                settings: settings,
                reason: description
            )
        }
    }

    private func handleDeferredRevalidationFailure(
        key: String,
        settings: AppSettings,
        reason: String
    ) {
        let now = now()
        if let entitlement = settings.currentLicenseEntitlement,
           entitlement.isCurrentlyValid(at: now) {
            activationState = .licensed
            logger.info("License re-validation deferred: \(reason, privacy: .public)")
            let retryAt = min(
                entitlement.claims.expiresAt,
                now.addingTimeInterval(Self.revalidationInterval)
            )
            revalidationTask?.cancel()
            revalidationTask = Task { [weak self] in
                let delay = retryAt.timeIntervalSince(now)
                guard delay > 0 else {
                    await self?.revalidateLicense(key: key, settings: settings)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.revalidateLicense(key: key, settings: settings)
            }
            return
        }

        settings.updateLicenseEntitlement(nil)
        refreshState(settings: settings)
    }

    private func verifyLicense(
        key: String,
        existingEntitlement: LicenseEntitlement?
    ) async -> LicenseValidationResult {
        if let backendURL = verificationConfiguration.entitlementServiceURL,
           let publicKey = verificationConfiguration.entitlementPublicKeyBase64 {
            return await verifyWithSignedBackend(
                key: key,
                backendURL: backendURL,
                publicKeyBase64: publicKey
            )
        }

        if verificationConfiguration.requiresSignedEntitlement {
            logger.error("Signed entitlement verification required but not configured.")
            return .invalid(reason: "This build requires a configured license entitlement service.")
        }

#if DEBUG
        guard verificationConfiguration.allowGumroadFallback else {
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

            guard httpResponse.statusCode == 200,
                  let envelope = try? JSONDecoder().decode(
                    SignedEntitlementEnvelope.self,
                    from: data
                  ),
                  let entitlement = Self.decodeSignedEntitlement(
                    envelope.token,
                    expectedProductID: Self.gumroadProductID,
                    publicKeyBase64: publicKeyBase64,
                    validatedAt: now()
                  ) else {
                return .invalid(reason: "Invalid license key.")
            }

            return .valid(entitlement)
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
                        licenseID: licenseIdentifier(from: purchase, key: key),
                        issuedAt: validatedAt,
                        refreshAfter: validatedAt.addingTimeInterval(Self.revalidationInterval),
                        expiresAt: validatedAt.addingTimeInterval(Self.offlineEntitlementDuration),
                        featureFlags: featureFlags(from: purchase, existingEntitlement: existingEntitlement)
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

    private func licenseIdentifier(from purchase: [String: Any], key: String) -> String {
        if let id = purchase["id"] as? String, !id.isEmpty {
            return id
        }
        return sha256Hex(key)
    }

    private func featureFlags(
        from purchase: [String: Any],
        existingEntitlement: LicenseEntitlement?
    ) -> [String: Bool] {
        if let flags = purchase["feature_flags"] as? [String: Bool] {
            return flags
        }
        return existingEntitlement?.claims.featureFlags ?? [:]
    }

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeSignedEntitlement(
        _ token: String,
        expectedProductID: String,
        publicKeyBase64: String,
        validatedAt: Date
    ) -> LicenseEntitlement? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = base64URLDecode(String(parts[0])),
              let signature = base64URLDecode(String(parts[1])),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let claims = try? JSONDecoder().decode(LicenseEntitlementClaims.self, from: payloadData) else {
            return nil
        }

        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: payloadData) else {
            return nil
        }

        guard claims.productID == expectedProductID,
              claims.issuedAt <= claims.refreshAfter,
              claims.refreshAfter <= claims.expiresAt,
              claims.expiresAt > validatedAt else {
            return nil
        }

        return LicenseEntitlement(
            claims: claims,
            source: .signedBackend,
            token: token,
            signature: signature,
            validatedAt: validatedAt
        )
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
