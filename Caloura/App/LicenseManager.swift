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

struct LicenseVerificationConfiguration: Equatable, Sendable {
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
@Observable
final class LicenseManager {
    static let gumroadPurchaseURL = URL(string: "https://babayosa.gumroad.com/l/bmokl")!
    static let trialDurationDays = 7
    private static let revalidationInterval: TimeInterval = 86_400

    @ObservationIgnored private static let logger = Logger(subsystem: "com.caloura.app", category: "License")
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let verifier: LicenseEntitlementVerifier
    @ObservationIgnored private let licensePersistenceMatchesMemory: @MainActor (AppSettings) -> Bool

    private(set) var activationState: ActivationState = .checking

    @ObservationIgnored private var revalidationTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        verificationConfiguration: LicenseVerificationConfiguration = .bundleDefault(),
        licensePersistenceMatchesMemory: @escaping @MainActor (AppSettings) -> Bool = {
            $0.licenseStatePersistenceMatchesMemory()
        }
    ) {
        self.now = now
        self.licensePersistenceMatchesMemory = licensePersistenceMatchesMemory
        self.verifier = LicenseEntitlementVerifier(
            session: session,
            now: now,
            configuration: verificationConfiguration,
            logger: Self.logger
        )
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

        switch await verifier.verify(key: normalizedKey, existingEntitlement: settings.currentLicenseEntitlement) {
        case .valid(let entitlement):
            settings.licenseKey = normalizedKey
            settings.updateLicenseEntitlement(entitlement)
            guard licensePersistenceMatchesMemory(settings) else {
                settings.licenseKey = ""
                settings.updateLicenseEntitlement(nil)
                activationState = .activationFailed("License could not be saved securely.")
                Self.logger.error("License activation failed: secure persistence verification failed.")
                return
            }
            activationState = .licensed
            scheduleRevalidationIfNeeded(settings: settings)
            Self.logger.info("License activated successfully.")
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
                Self.logger.info("License key empty but entitlement present — revoking.")
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

        switch await verifier.verify(key: key, existingEntitlement: existingEntitlement) {
        case .valid(let entitlement):
            settings.updateLicenseEntitlement(entitlement)
            guard licensePersistenceMatchesMemory(settings) else {
                Self.logger.error("License re-validation failed: secure persistence verification failed.")
                settings.updateLicenseEntitlement(existingEntitlement)
                handleDeferredRevalidationFailure(
                    key: key,
                    settings: settings,
                    reason: "secure persistence failure",
                    entitlementForDeferral: existingEntitlement
                )
                return
            }
            activationState = .licensed
            scheduleRevalidationIfNeeded(settings: settings)
            Self.logger.info("License re-validation succeeded.")
        case .invalid:
            Self.logger.info("License re-validation failed. Revoking activation.")
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
        reason: String,
        entitlementForDeferral: LicenseEntitlement? = nil
    ) {
        let now = now()
        if let entitlement = entitlementForDeferral ?? settings.currentLicenseEntitlement,
           entitlement.isCurrentlyValid(at: now) {
            activationState = .licensed
            Self.logger.info("License re-validation deferred: \(reason, privacy: .public)")
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

}
