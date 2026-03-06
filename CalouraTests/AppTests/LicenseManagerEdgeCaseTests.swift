import XCTest
@testable import Caloura

@MainActor
final class LicenseManagerEdgeCaseTests: XCTestCase {

    nonisolated(unsafe) private var settings: AppSettings!
    nonisolated(unsafe) private var license: LicenseManager!

    nonisolated(unsafe) private var savedFirstLaunchDate: Date!
    nonisolated(unsafe) private var savedLicenseKey: String!
    nonisolated(unsafe) private var savedEntitlement: LicenseEntitlement?
    nonisolated(unsafe) private var savedLastValidationDate: Date?
    nonisolated(unsafe) private var savedFurthestDateSeen: Date?

    override func setUp() {
        super.setUp()
        let settings = MainActor.assumeIsolated {
            AppSettings.shared
        }
        self.settings = settings
        let snapshot = MainActor.assumeIsolated {
            (
                settings.firstLaunchDate,
                settings.licenseKey,
                settings.currentLicenseEntitlement,
                settings.lastLicenseValidationDate,
                settings.furthestDateSeen
            )
        }
        savedFirstLaunchDate = snapshot.0
        savedLicenseKey = snapshot.1
        savedEntitlement = snapshot.2
        savedLastValidationDate = snapshot.3
        savedFurthestDateSeen = snapshot.4

        MainActor.assumeIsolated {
            settings.licenseKey = ""
            settings.updateLicenseEntitlement(nil)
            settings.lastLicenseValidationDate = nil
            settings.furthestDateSeen = nil
        }

        self.license = MainActor.assumeIsolated {
            LicenseManager(settings: settings)
        }
    }

    override func tearDown() {
        guard let settings else {
            super.tearDown()
            return
        }
        let restoredFirstLaunchDate: Date = savedFirstLaunchDate
        let restoredLicenseKey: String = savedLicenseKey
        let restoredEntitlement = savedEntitlement
        let restoredLastValidationDate = savedLastValidationDate
        let restoredFurthestDateSeen = savedFurthestDateSeen
        MainActor.assumeIsolated {
            settings.firstLaunchDate = restoredFirstLaunchDate
            settings.licenseKey = restoredLicenseKey
            settings.updateLicenseEntitlement(restoredEntitlement)
            settings.lastLicenseValidationDate = restoredLastValidationDate
            settings.furthestDateSeen = restoredFurthestDateSeen
        }
        super.tearDown()
    }

    // MARK: - Exact day 7 boundary

    func testTrialDaysRemaining_exactlyDay7() {
        // firstLaunch = 7 days ago => elapsed = 7, remaining = max(0, 7-7) = 0
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: -7, to: Date()
        )!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 0)
    }

    func testIsTrialExpired_exactlyDay7() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: -7, to: Date()
        )!
        XCTAssertTrue(license.isTrialExpired(settings: settings))
    }

    func testActivationState_exactlyDay7() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: -7, to: Date()
        )!
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .expired)
    }

    // MARK: - Just under 7 days (6 days 23 hours ago)

    func testTrialDaysRemaining_justUnder7Days() {
        // 6 days and 23 hours ago => dateComponents(.day) truncates to 6
        // remaining = max(0, 7-6) = 1
        let sixDays23Hours = Calendar.current.date(
            byAdding: .day, value: -7, to: Date()
        )!.addingTimeInterval(3600) // +1 hour = 6d23h ago
        settings.firstLaunchDate = sixDays23Hours
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 1)
    }

    func testIsTrialExpired_justUnder7Days() {
        let sixDays23Hours = Calendar.current.date(
            byAdding: .day, value: -7, to: Date()
        )!.addingTimeInterval(3600)
        settings.firstLaunchDate = sixDays23Hours
        XCTAssertFalse(license.isTrialExpired(settings: settings))
    }

    func testActivationState_justUnder7Days() {
        let sixDays23Hours = Calendar.current.date(
            byAdding: .day, value: -7, to: Date()
        )!.addingTimeInterval(3600)
        settings.firstLaunchDate = sixDays23Hours
        license.refreshState(settings: settings)
        XCTAssertEqual(
            license.activationState,
            .trial(daysRemaining: 1)
        )
    }

    // MARK: - Future firstLaunchDate

    func testTrialDaysRemaining_futureDate_clampedTo7() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: 5, to: Date()
        )!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 7)
    }

    func testIsTrialExpired_futureDate() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: 5, to: Date()
        )!
        XCTAssertFalse(license.isTrialExpired(settings: settings))
    }

    func testShouldShowNag_futureDate() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: 5, to: Date()
        )!
        XCTAssertFalse(license.shouldShowNag(settings: settings))
    }

    // MARK: - Very old firstLaunchDate

    func testTrialDaysRemaining_365DaysAgo_isZeroNotNegative() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: -365, to: Date()
        )!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 0)
    }

    func testIsTrialExpired_365DaysAgo() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: -365, to: Date()
        )!
        XCTAssertTrue(license.isTrialExpired(settings: settings))
    }

    func testShouldShowNag_365DaysAgo() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: -365, to: Date()
        )!
        XCTAssertTrue(license.shouldShowNag(settings: settings))
    }

    func testActivationState_365DaysAgo() {
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: -365, to: Date()
        )!
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .expired)
    }
}
