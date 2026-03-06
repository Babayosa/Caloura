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

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

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

    @Published private(set) var activationState: ActivationState = .checking

    private var revalidationTask: Task<Void, Never>?

    private static var entitlementServiceURL: URL? {
        guard let string = Bundle.main.object(
            forInfoDictionaryKey: "CalouraLicenseEntitlementURL"
        ) as? String else {
            return nil
        }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return URL(string: normalized)
    }

    private static var entitlementPublicKeyBase64: String? {
        guard let string = Bundle.main.object(
            forInfoDictionaryKey: "CalouraLicenseEntitlementPublicKey"
        ) as? String else {
            return nil
        }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private init() {
        self.session = .shared
        self.now = Date.init
        refreshState(settings: AppSettings.shared)
    }

    init(
        settings: AppSettings,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.now = now
        refreshState(settings: settings)
    }

    var trialDaysRemaining: Int {
        trialDaysRemaining(settings: AppSettings.shared)
    }

    var isTrialExpired: Bool {
        isTrialExpired(settings: AppSettings.shared)
    }

    var shouldShowNag: Bool {
        shouldShowNag(settings: AppSettings.shared)
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
        return max(0, Self.trialDurationDays - elapsed)
    }

    func isTrialExpired(settings: AppSettings) -> Bool {
        if settings.isLicenseActivated { return false }
        return trialDaysRemaining(settings: settings) == 0
    }

    func shouldShowNag(settings: AppSettings) -> Bool {
        isTrialExpired(settings: settings) && !settings.isLicenseActivated
    }

    func refreshState() {
        refreshState(settings: AppSettings.shared)
    }

    func refreshState(settings: AppSettings) {
        let state = currentLicenseState(settings: settings)
        activationState = activationState(for: state)
        scheduleRevalidationIfNeeded(settings: settings)
    }

    func activate(licenseKey: String) async {
        await activate(licenseKey: licenseKey, settings: AppSettings.shared)
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

        let shouldRevalidate = entitlement.claims.refreshAfter <= now || !entitlement.isCurrentlyValid(at: now)
        guard shouldRevalidate else { return }

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
            logger.info("License re-validation succeeded.")
        case .invalid:
            logger.info("License re-validation failed. Revoking activation.")
            settings.updateLicenseEntitlement(nil)
            refreshState(settings: settings)
        case .ambiguousResponse:
            handleDeferredRevalidationFailure(settings: settings, reason: "ambiguous response")
        case .networkError(let description):
            handleDeferredRevalidationFailure(settings: settings, reason: description)
        }
    }

    private func handleDeferredRevalidationFailure(settings: AppSettings, reason: String) {
        let now = now()
        if settings.currentLicenseEntitlement?.isCurrentlyValid(at: now) == true {
            activationState = .licensed
            logger.info("License re-validation deferred: \(reason, privacy: .public)")
            return
        }

        settings.updateLicenseEntitlement(nil)
        refreshState(settings: settings)
    }

    private func verifyLicense(
        key: String,
        existingEntitlement: LicenseEntitlement?
    ) async -> LicenseValidationResult {
        if let backendURL = Self.entitlementServiceURL,
           let publicKey = Self.entitlementPublicKeyBase64 {
            return await verifyWithSignedBackend(
                key: key,
                backendURL: backendURL,
                publicKeyBase64: publicKey
            )
        }

        return await verifyWithGumroadFallback(
            key: key,
            existingEntitlement: existingEntitlement
        )
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
