import Foundation
import os.log

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
    private static let revalidationInterval: TimeInterval = 86_400 // 1 day

    private let logger = Logger(subsystem: "com.caloura.app", category: "License")

    @Published private(set) var activationState: ActivationState = .checking

    private init() {
        refreshState()
    }

    // For testing: allow injecting settings
    init(settings: AppSettings) {
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

    // MARK: - Testable Core Logic

    func trialDaysRemaining(settings: AppSettings) -> Int {
        // Use the later of current date and furthest-seen date to resist clock rollback (S2-15)
        let now = Date()
        let effectiveNow = max(now, settings.furthestDateSeen ?? now)
        if now >= (settings.furthestDateSeen ?? .distantPast) {
            settings.furthestDateSeen = now
        }
        let elapsed = Calendar.current.dateComponents(
            [.day], from: settings.firstLaunchDate, to: effectiveNow
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
        if settings.isLicenseActivated {
            activationState = .licensed
            scheduleRevalidationIfNeeded(settings: settings)
        } else if isTrialExpired(settings: settings) {
            activationState = .expired
        } else {
            activationState = .trial(daysRemaining: trialDaysRemaining(settings: settings))
        }
    }

    private func scheduleRevalidationIfNeeded(settings: AppSettings) {
        let needsRevalidation: Bool
        if let lastValidation = settings.lastLicenseValidationDate {
            // Reject future-dated validation timestamps (S2-17)
            if lastValidation > Date() {
                needsRevalidation = true
            } else {
                needsRevalidation = Date().timeIntervalSince(lastValidation) > Self.revalidationInterval
            }
        } else {
            needsRevalidation = true
        }

        guard needsRevalidation else { return }

        let key = settings.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            // Empty key with active license is invalid — revoke (S2-16)
            logger.info("License key empty but activated — revoking.")
            settings.isLicenseActivated = false
            refreshState(settings: settings)
            return
        }

        Task { [weak self] in
            await self?.revalidateLicense(key: key, settings: settings)
        }
    }

    private func revalidateLicense(key: String, settings: AppSettings) async {
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
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.url?.host == Self.gumroadVerifyURL.host,
                  data.count < 1_000_000 else {
                return // Ambiguous response — skip, don't revoke
            }

            guard httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success else {
                // Definitive invalid response — revoke
                logger.info("License re-validation failed. Revoking activation.")
                settings.isLicenseActivated = false
                refreshState(settings: settings)
                return
            }

            // Check for refund/dispute/chargeback
            if let purchase = json["purchase"] as? [String: Any] {
                if purchase["refunded"] as? Bool == true ||
                   purchase["disputed"] as? Bool == true ||
                   purchase["chargebacked"] as? Bool == true {
                    logger.info("License revoked: refunded or disputed.")
                    settings.isLicenseActivated = false
                    refreshState(settings: settings)
                    return
                }
            }

            // Still valid — update timestamp
            settings.lastLicenseValidationDate = Date()
            logger.info("License re-validation succeeded.")

        } catch {
            // Network error — skip re-validation, don't revoke
            logger.info("License re-validation skipped due to network error.")
        }
    }

    // MARK: - Gumroad Activation

    func activate(licenseKey: String) async {
        await activate(licenseKey: licenseKey, settings: AppSettings.shared)
    }

    func activate(licenseKey: String, settings: AppSettings) async {
        activationState = .checking

        var request = URLRequest(url: Self.gumroadVerifyURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "product_id", value: Self.gumroadProductID),
            URLQueryItem(name: "license_key", value: licenseKey)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard data.count < 1_000_000 else {
                activationState = .activationFailed("Unexpected response from server.")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.url?.host == Self.gumroadVerifyURL.host else {
                activationState = .activationFailed("Unexpected response from server.")
                return
            }

            guard httpResponse.statusCode == 200 else {
                activationState = .activationFailed("Invalid license key.")
                return
            }

            // Parse Gumroad JSON response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success else {
                activationState = .activationFailed("Invalid license key.")
                return
            }

            // Check for refund/dispute/chargeback
            if let purchase = json["purchase"] as? [String: Any] {
                if purchase["refunded"] as? Bool == true ||
                   purchase["disputed"] as? Bool == true ||
                   purchase["chargebacked"] as? Bool == true {
                    activationState = .activationFailed("This license has been refunded or disputed.")
                    return
                }
            }

            // Activation successful
            settings.licenseKey = licenseKey
            settings.isLicenseActivated = true
            settings.lastLicenseValidationDate = Date()
            activationState = .licensed
            logger.info("License activated successfully.")

        } catch {
            logger.error("Activation failed: \(error.localizedDescription)")
            activationState = .activationFailed("Network error. Please check your connection and try again.")
        }
    }
}
