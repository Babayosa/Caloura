import XCTest
@testable import Caloura

@MainActor
final class LicenseManagerTests: XCTestCase {

    nonisolated(unsafe) private var settings: AppSettings!
    nonisolated(unsafe) private var license: LicenseManager!

    nonisolated(unsafe) private var savedFirstLaunchDate: Date!
    nonisolated(unsafe) private var savedLicenseKey: String!
    nonisolated(unsafe) private var savedEntitlement: LicenseEntitlement?
    nonisolated(unsafe) private var savedLastValidationDate: Date?
    nonisolated(unsafe) private var savedFurthestDateSeen: Date?

    override nonisolated func setUp() {
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

    override nonisolated func tearDown() {
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

    func testActivate_emptyKey_setsActivationFailed() async {
        await license.activate(licenseKey: "   ", settings: settings)

        XCTAssertEqual(license.activationState, .activationFailed("Enter a license key."))
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testRefreshState_validEntitlementWinsOverExpiredTrial() {
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        settings.licenseKey = "VALID-KEY-1234"
        settings.updateLicenseEntitlement(makeTestEntitlement())

        license.refreshState(settings: settings)

        XCTAssertEqual(license.activationState, .licensed)
    }

    func testRefreshState_expiredEntitlementFallsBackToTrial() {
        let now = Date()
        settings.firstLaunchDate = now
        settings.licenseKey = "VALID-KEY-1234"
        settings.updateLicenseEntitlement(
            LicenseEntitlement(
                claims: LicenseEntitlementClaims(
                    productID: "bmokl",
                    licenseID: "expired",
                    issuedAt: now.addingTimeInterval(-600),
                    refreshAfter: now.addingTimeInterval(-300),
                    expiresAt: now.addingTimeInterval(-1),
                    featureFlags: [:]
                ),
                source: .signedBackend,
                token: "token",
                signature: Data(),
                validatedAt: now.addingTimeInterval(-600)
            )
        )

        license.refreshState(settings: settings)

        XCTAssertEqual(license.activationState, .trial(daysRemaining: 7))
    }

    func testTrialDaysRemaining_usesFurthestDateSeenToPreventClockRollback() {
        let now = Date()
        settings.firstLaunchDate = Calendar.current.date(byAdding: .day, value: -4, to: now)!
        settings.furthestDateSeen = Calendar.current.date(byAdding: .day, value: 2, to: now)

        let days = license.trialDaysRemaining(settings: settings)

        XCTAssertEqual(days, 1)
        XCTAssertEqual(settings.furthestDateSeen, Calendar.current.date(byAdding: .day, value: 2, to: now))
    }

    func testBundleDefault_trimsConfigValuesAndParsesTruthiness() throws {
        let bundle = try makeTestBundle(infoDictionary: [
            "CalouraRequireSignedEntitlement": " yes ",
            "CalouraLicenseEntitlementURL": "  https://license.caloura.test/verify  ",
            "CalouraLicenseEntitlementPublicKey": "  test-public-key  "
        ])

        let configuration = LicenseVerificationConfiguration.bundleDefault(bundle: bundle)

        XCTAssertEqual(
            configuration.entitlementServiceURL,
            URL(string: "https://license.caloura.test/verify")
        )
        XCTAssertEqual(configuration.entitlementPublicKeyBase64, "test-public-key")
        XCTAssertTrue(configuration.requiresSignedEntitlement)
        XCTAssertFalse(configuration.allowGumroadFallback)
    }

    func testBundleDefault_blankOrInvalidValuesNormalizeToNilAndFalse() throws {
        let bundle = try makeTestBundle(infoDictionary: [
            "CalouraRequireSignedEntitlement": ["unexpected"],
            "CalouraLicenseEntitlementURL": "   ",
            "CalouraLicenseEntitlementPublicKey": "\n\t"
        ])

        let configuration = LicenseVerificationConfiguration.bundleDefault(bundle: bundle)

        XCTAssertNil(configuration.entitlementServiceURL)
        XCTAssertNil(configuration.entitlementPublicKeyBase64)
        XCTAssertFalse(configuration.requiresSignedEntitlement)
        XCTAssertTrue(configuration.allowGumroadFallback)
    }

    private func makeTestBundle(infoDictionary: [String: Any]) throws -> Bundle {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-license-tests-\(UUID().uuidString)")
        let bundleURL = rootURL.appendingPathComponent("LicenseTest.bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist = infoDictionary.merging([
            "CFBundleIdentifier": "com.caloura.tests.license.bundle.\(UUID().uuidString)",
            "CFBundleName": "LicenseTestBundle",
            "CFBundlePackageType": "BNDL"
        ]) { current, _ in current }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)

        guard let bundle = Bundle(url: bundleURL) else {
            XCTFail("Failed to create test bundle")
            throw NSError(domain: "LicenseManagerTests", code: 1)
        }
        return bundle
    }
}
