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

    static let gumroadProductID = "bmokl"
    static let gumroadVerifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
    static let gumroadPurchaseURL = URL(string: "https://babayosa.gumroad.com/l/bmokl")!
    static let trialDurationDays = 7

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
        let elapsed = Calendar.current.dateComponents(
            [.day], from: settings.firstLaunchDate, to: Date()
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
        } else if isTrialExpired(settings: settings) {
            activationState = .expired
        } else {
            activationState = .trial(daysRemaining: trialDaysRemaining(settings: settings))
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

        let body = "product_id=\(Self.gumroadProductID)&license_key=\(licenseKey)"
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
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

            // Activation successful
            settings.licenseKey = licenseKey
            settings.isLicenseActivated = true
            activationState = .licensed
            logger.info("License activated successfully.")

        } catch {
            logger.error("Activation failed: \(error.localizedDescription)")
            activationState = .activationFailed("Network error. Please check your connection and try again.")
        }
    }
}
