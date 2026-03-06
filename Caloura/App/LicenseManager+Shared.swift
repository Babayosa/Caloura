import Foundation

extension LicenseManager {
    static let shared = LicenseManager(settings: AppSettings.shared)

    var trialDaysRemaining: Int {
        trialDaysRemaining(settings: AppSettings.shared)
    }

    var isTrialExpired: Bool {
        isTrialExpired(settings: AppSettings.shared)
    }

    var shouldShowNag: Bool {
        shouldShowNag(settings: AppSettings.shared)
    }

    func refreshState() {
        refreshState(settings: AppSettings.shared)
    }

    func activate(licenseKey: String) async {
        await activate(licenseKey: licenseKey, settings: AppSettings.shared)
    }
}
