import XCTest
@testable import Caloura

@MainActor
final class LicenseManagerTests: XCTestCase {

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

    // MARK: - Trial Days Remaining

    func testTrialDaysRemaining_day1() {
        settings.firstLaunchDate = Date()
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 7)
    }

    func testTrialDaysRemaining_day4() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -4, to: Date())!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 3)
    }

    func testTrialDaysRemaining_day8() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -8, to: Date())!
        let days = license.trialDaysRemaining(settings: settings)
        XCTAssertEqual(days, 0)
    }

    // MARK: - Trial Expired

    func testIsTrialExpired_withinTrial() {
        settings.firstLaunchDate = Date()
        XCTAssertFalse(license.isTrialExpired(settings: settings))
    }

    func testIsTrialExpired_afterTrial() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -8, to: Date())!
        XCTAssertTrue(license.isTrialExpired(settings: settings))
    }

    func testIsTrialExpired_whenLicensed() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -8, to: Date())!
        settings.licenseKey = "VALID-KEY-1234"
        settings.updateLicenseEntitlement(makeTestEntitlement())
        XCTAssertFalse(license.isTrialExpired(settings: settings))
    }

    // MARK: - Nag Logic

    func testShouldShowNag_duringTrial() {
        settings.firstLaunchDate = Date()
        XCTAssertFalse(license.shouldShowNag(settings: settings))
    }

    func testShouldShowNag_expiredAndUnlicensed() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -8, to: Date())!
        XCTAssertTrue(license.shouldShowNag(settings: settings))
    }

    func testShouldShowNag_expiredAndLicensed() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -8, to: Date())!
        settings.licenseKey = "VALID-KEY-1234"
        settings.updateLicenseEntitlement(makeTestEntitlement())
        XCTAssertFalse(license.shouldShowNag(settings: settings))
    }

    // MARK: - Activation State

    func testActivationState_licensed() {
        settings.licenseKey = "XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX"
        settings.updateLicenseEntitlement(makeTestEntitlement())
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .licensed)
    }

    func testActivationState_licensed_emptyKeyRevokes() {
        // S2-16: Empty key with isLicenseActivated=true must revoke
        settings.licenseKey = ""
        settings.updateLicenseEntitlement(makeTestEntitlement())
        license.refreshState(settings: settings)
        XCTAssertFalse(settings.isLicenseActivated)
        XCTAssertNotEqual(license.activationState, .licensed)
    }

    func testActivationState_trial() {
        settings.firstLaunchDate = Date()
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .trial(daysRemaining: 7))
    }

    func testActivationState_expired() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -8, to: Date())!
        license.refreshState(settings: settings)
        XCTAssertEqual(license.activationState, .expired)
    }
}
