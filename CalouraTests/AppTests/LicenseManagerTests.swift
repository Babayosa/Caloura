import XCTest
@testable import Caloura

@MainActor
final class LicenseManagerTests: XCTestCase {

    private var settings: AppSettings!
    private var license: LicenseManager!

    private var savedFirstLaunchDate: Date!
    private var savedLicenseKey: String!
    private var savedIsLicenseActivated: Bool!

    override func setUp() {
        super.setUp()
        settings = AppSettings.shared

        // Save original values
        savedFirstLaunchDate = settings.firstLaunchDate
        savedLicenseKey = settings.licenseKey
        savedIsLicenseActivated = settings.isLicenseActivated

        // Reset to unlicensed state
        settings.licenseKey = ""
        settings.isLicenseActivated = false

        license = LicenseManager(settings: settings)
    }

    override func tearDown() {
        // Restore original values
        settings.firstLaunchDate = savedFirstLaunchDate
        settings.licenseKey = savedLicenseKey
        settings.isLicenseActivated = savedIsLicenseActivated
        super.tearDown()
    }

    // MARK: - Trial Days Remaining

    func testTrialDaysRemaining_day1() {
        settings.firstLaunchDate = Date()
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 30)
    }

    func testTrialDaysRemaining_day15() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -15, to: Date())!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 15)
    }

    func testTrialDaysRemaining_day31() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 0)
    }

    // MARK: - Trial Expired

    func testIsTrialExpired_withinTrial() {
        settings.firstLaunchDate = Date()
        XCTAssertFalse(license.isTrialExpired(settings: settings))
    }

    func testIsTrialExpired_afterTrial() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        XCTAssertTrue(license.isTrialExpired(settings: settings))
    }

    func testIsTrialExpired_whenLicensed() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        settings.isLicenseActivated = true
        XCTAssertFalse(license.isTrialExpired(settings: settings))
    }

    // MARK: - Nag Logic

    func testShouldShowNag_duringTrial() {
        settings.firstLaunchDate = Date()
        XCTAssertFalse(license.shouldShowNag(settings: settings))
    }

    func testShouldShowNag_expiredAndUnlicensed() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        XCTAssertTrue(license.shouldShowNag(settings: settings))
    }

    func testShouldShowNag_expiredAndLicensed() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        settings.isLicenseActivated = true
        XCTAssertFalse(license.shouldShowNag(settings: settings))
    }

    // MARK: - Activation State

    func testActivationState_licensed() {
        settings.isLicenseActivated = true
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .licensed)
    }

    func testActivationState_trial() {
        settings.firstLaunchDate = Date()
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .trial(daysRemaining: 30))
    }

    func testActivationState_expired() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .expired)
    }
}
