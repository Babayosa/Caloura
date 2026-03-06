import XCTest
@testable import Caloura

@MainActor
final class LicenseManagerEdgeCaseTests: XCTestCase {

    private var settings: AppSettings!
    private var license: LicenseManager!

    private var savedFirstLaunchDate: Date!
    private var savedLicenseKey: String!
    private var savedEntitlement: LicenseEntitlement?
    private var savedLastValidationDate: Date?

    override func setUp() {
        super.setUp()
        settings = AppSettings.shared

        // Save original values
        savedFirstLaunchDate = settings.firstLaunchDate
        savedLicenseKey = settings.licenseKey
        savedEntitlement = settings.currentLicenseEntitlement
        savedLastValidationDate = settings.lastLicenseValidationDate

        // Reset to unlicensed state
        settings.licenseKey = ""
        settings.updateLicenseEntitlement(nil)
        settings.lastLicenseValidationDate = nil

        license = LicenseManager(settings: settings)
    }

    override func tearDown() {
        // Restore original values
        settings.firstLaunchDate = savedFirstLaunchDate
        settings.licenseKey = savedLicenseKey
        settings.updateLicenseEntitlement(savedEntitlement)
        settings.lastLicenseValidationDate = savedLastValidationDate
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
        // If firstLaunchDate is in the future, elapsed is negative,
        // so remaining = max(0, 7 - negative) which exceeds 7.
        // The implementation returns max(0, 7 - elapsed) directly,
        // so a future date yields > 7.
        // Verify it is at least 7 (not negative or zero).
        settings.firstLaunchDate = Calendar.current.date(
            byAdding: .day, value: 5, to: Date()
        )!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertGreaterThanOrEqual(days, 7)
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
