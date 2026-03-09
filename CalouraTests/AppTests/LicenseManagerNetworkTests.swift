import XCTest
@testable import Caloura

// MARK: - Mock URL Protocol

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Handler returns (response, data) or throws an error.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        // Only intercept requests to the Gumroad API
        request.url?.host == "api.gumroad.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helper Functions

private func makeGumroadResponse(
    json: [String: Any],
    statusCode: Int = 200,
    url: URL? = nil
) throws -> (HTTPURLResponse, Data) {
    let responseURL = url ?? URL(string: "https://api.gumroad.com/v2/licenses/verify")!
    let response = HTTPURLResponse(
        url: responseURL,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    let data = try JSONSerialization.data(withJSONObject: json)
    return (response, data)
}

private func makeSuccessJSON(
    refunded: Bool = false,
    disputed: Bool = false,
    chargebacked: Bool = false,
    purchaseOverrides: [String: Any] = [:]
) -> [String: Any] {
    var purchase: [String: Any] = [
        "refunded": refunded,
        "disputed": disputed,
        "chargebacked": chargebacked,
        "email": "test@example.com"
    ]
    for (key, value) in purchaseOverrides {
        purchase[key] = value
    }
    return [
        "success": true,
        "purchase": purchase
    ]
}

// MARK: - Tests

@MainActor
final class LicenseManagerNetworkTests: XCTestCase {

    nonisolated(unsafe) private var settings: AppSettings!
    nonisolated(unsafe) private var license: LicenseManager!

    nonisolated(unsafe) private var savedFirstLaunchDate: Date!
    nonisolated(unsafe) private var savedLicenseKey: String!
    nonisolated(unsafe) private var savedEntitlement: LicenseEntitlement?
    nonisolated(unsafe) private var savedLastValidationDate: Date?

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let settings = MainActor.assumeIsolated {
            AppSettings.shared
        }
        self.settings = settings
        let snapshot = MainActor.assumeIsolated {
            (
                settings.firstLaunchDate,
                settings.licenseKey,
                settings.currentLicenseEntitlement,
                settings.lastLicenseValidationDate
            )
        }
        savedFirstLaunchDate = snapshot.0
        savedLicenseKey = snapshot.1
        savedEntitlement = snapshot.2
        savedLastValidationDate = snapshot.3

        MainActor.assumeIsolated {
            settings.licenseKey = ""
            settings.updateLicenseEntitlement(nil)
            settings.lastLicenseValidationDate = nil
        }

        self.license = MainActor.assumeIsolated {
            LicenseManager(settings: settings)
        }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
        guard let settings else {
            super.tearDown()
            return
        }
        let restoredFirstLaunchDate: Date = savedFirstLaunchDate
        let restoredLicenseKey: String = savedLicenseKey
        let restoredEntitlement = savedEntitlement
        let restoredLastValidationDate = savedLastValidationDate
        MainActor.assumeIsolated {
            settings.firstLaunchDate = restoredFirstLaunchDate
            settings.licenseKey = restoredLicenseKey
            settings.updateLicenseEntitlement(restoredEntitlement)
            settings.lastLicenseValidationDate = restoredLastValidationDate
        }
        super.tearDown()
    }

    // MARK: - Activation Tests

    func testActivate_validSuccess_setsLicensed() async {
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON())
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        XCTAssertEqual(license.activationState, .licensed)
        XCTAssertTrue(settings.isLicenseActivated)
        XCTAssertEqual(settings.licenseKey, "AAAA-BBBB-CCCC-DDDD")
    }

    func testActivate_successWithPurchaseIDAndFeatureFlags_usesPurchaseValues() async {
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON(
                purchaseOverrides: [
                    "id": "gumroad-purchase-id",
                    "feature_flags": ["pro": true, "ocr": true]
                ]
            ))
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        XCTAssertEqual(license.activationState, .licensed)
        XCTAssertEqual(settings.currentLicenseEntitlement?.claims.licenseID, "gumroad-purchase-id")
        XCTAssertEqual(
            settings.currentLicenseEntitlement?.claims.featureFlags,
            ["pro": true, "ocr": true]
        )
    }

    func testActivate_refundedPurchase_fails() async {
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON(refunded: true))
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_disputedPurchase_fails() async {
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON(disputed: true))
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_chargebackedPurchase_fails() async {
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON(chargebacked: true))
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_invalidJSON_fails() async {
        MockURLProtocol.requestHandler = { _ in
            let url = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("not json at all".utf8))
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_http500_fails() async {
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: ["success": false], statusCode: 500)
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_oversizedResponse_fails() async {
        MockURLProtocol.requestHandler = { _ in
            let url = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            // 1MB + 1 byte
            let bigData = Data(repeating: 0x41, count: 1_000_001)
            return (response, bigData)
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected — oversized response triggers "Unexpected response"
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_wrongHostRedirect_fails() async {
        MockURLProtocol.requestHandler = { _ in
            // Simulate a redirect: the response URL differs from the request URL
            let redirectedURL = URL(string: "https://evil.com/v2/licenses/verify")!
            let response = HTTPURLResponse(
                url: redirectedURL, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let data = try JSONSerialization.data(
                withJSONObject: makeSuccessJSON()
            )
            return (response, data)
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected — host mismatch triggers "Unexpected response"
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_successFalse_fails() async {
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: ["success": false, "message": "Invalid license key"])
        }

        await license.activate(licenseKey: "INVALID-KEY", settings: settings)

        if case .activationFailed = license.activationState {
            // Expected
        } else {
            XCTFail("Expected activationFailed, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testActivate_networkError_fails() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await license.activate(licenseKey: "AAAA-BBBB-CCCC-DDDD", settings: settings)

        if case .activationFailed(let msg) = license.activationState {
            XCTAssertTrue(msg.contains("Network error"))
        } else {
            XCTFail("Expected activationFailed with network error, got \(license.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    // MARK: - Revalidation Tests

    func testRevalidation_refund_revokesLicense() async {
        // Set up as already licensed with a stale validation date to trigger revalidation
        settings.licenseKey = "VALID-KEY-1234"
        let staleDate = Date().addingTimeInterval(-2 * 86_400)
        settings.updateLicenseEntitlement(makeTestEntitlement(
            validatedAt: staleDate,
            refreshAfter: staleDate,
            expiresAt: staleDate.addingTimeInterval(7 * 86_400)
        ))

        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON(refunded: true))
        }

        // refreshState triggers revalidation when isLicenseActivated=true and date is stale
        license.refreshState(settings: settings)

        await pollUntil { [self] in !self.settings.isLicenseActivated }

        XCTAssertFalse(settings.isLicenseActivated)
    }

    func testRevalidation_networkError_doesNotRevoke() async {
        settings.licenseKey = "VALID-KEY-1234"
        let staleDate = Date().addingTimeInterval(-2 * 86_400)
        settings.updateLicenseEntitlement(makeTestEntitlement(
            validatedAt: staleDate,
            refreshAfter: staleDate,
            expiresAt: staleDate.addingTimeInterval(7 * 86_400)
        ))

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        license.refreshState(settings: settings)

        // Network errors don't change activation — poll briefly to let async complete
        await pollUntil { [self] in self.license.activationState == .licensed }

        // License should still be active — network errors are graceful
        XCTAssertTrue(settings.isLicenseActivated)
        XCTAssertEqual(license.activationState, .licensed)
    }

    func testRevalidation_oversizedResponse_doesNotRevoke() async {
        settings.licenseKey = "VALID-KEY-1234"
        let staleDate = Date().addingTimeInterval(-2 * 86_400)
        settings.updateLicenseEntitlement(makeTestEntitlement(
            validatedAt: staleDate,
            refreshAfter: staleDate,
            expiresAt: staleDate.addingTimeInterval(7 * 86_400)
        ))

        MockURLProtocol.requestHandler = { _ in
            let url = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let bigData = Data(repeating: 0x41, count: 1_000_001)
            return (response, bigData)
        }

        license.refreshState(settings: settings)

        await pollUntil { [self] in self.license.activationState == .licensed }

        // Oversized response is ambiguous — should NOT revoke
        XCTAssertTrue(settings.isLicenseActivated)
    }

    func testRevalidation_wrongHost_doesNotRevoke() async {
        settings.licenseKey = "VALID-KEY-1234"
        let staleDate = Date().addingTimeInterval(-2 * 86_400)
        settings.updateLicenseEntitlement(makeTestEntitlement(
            validatedAt: staleDate,
            refreshAfter: staleDate,
            expiresAt: staleDate.addingTimeInterval(7 * 86_400)
        ))

        MockURLProtocol.requestHandler = { _ in
            let redirectedURL = URL(string: "https://evil.com/v2/licenses/verify")!
            let response = HTTPURLResponse(
                url: redirectedURL, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let data = try JSONSerialization.data(withJSONObject: makeSuccessJSON())
            return (response, data)
        }

        license.refreshState(settings: settings)

        await pollUntil { [self] in self.license.activationState == .licensed }

        // Wrong host is ambiguous — should NOT revoke
        XCTAssertTrue(settings.isLicenseActivated)
    }

    func testRevalidation_validResponse_updatesTimestamp() async {
        settings.licenseKey = "VALID-KEY-1234"
        let staleDate = Date().addingTimeInterval(-2 * 86_400)
        settings.updateLicenseEntitlement(makeTestEntitlement(
            validatedAt: staleDate,
            refreshAfter: staleDate,
            expiresAt: staleDate.addingTimeInterval(7 * 86_400)
        ))

        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON())
        }

        license.refreshState(settings: settings)

        await pollUntil { [self] in
            if let date = self.settings.lastLicenseValidationDate { return date > staleDate }
            return false
        }

        XCTAssertTrue(settings.isLicenseActivated)
        // Validation date should be updated to something more recent than the stale date
        if let newDate = settings.lastLicenseValidationDate {
            XCTAssertGreaterThan(newDate, staleDate)
        } else {
            XCTFail("Expected lastLicenseValidationDate to be set")
        }
    }

    func testRefreshState_futureRefreshSchedulesDelayedRevalidation() async {
        let now = Date()
        let suiteName = "com.caloura.tests.license.delayed.\(UUID().uuidString)"
        let delayedDefaults = UserDefaults(suiteName: suiteName)!
        delayedDefaults.removePersistentDomain(forName: suiteName)
        let delayedSettings = AppSettings(defaults: delayedDefaults)
        delayedSettings.licenseKey = "VALID-KEY-1234"
        delayedSettings.updateLicenseEntitlement(makeTestEntitlement(
            validatedAt: now.addingTimeInterval(-300),
            refreshAfter: now.addingTimeInterval(0.5),
            expiresAt: now.addingTimeInterval(120)
        ))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.requestHandler = { _ in
            try makeGumroadResponse(json: makeSuccessJSON())
        }
        let manager = LicenseManager(
            settings: delayedSettings,
            session: session,
            now: { now },
            verificationConfiguration: LicenseVerificationConfiguration(
                entitlementServiceURL: nil,
                entitlementPublicKeyBase64: nil,
                requiresSignedEntitlement: false,
                allowGumroadFallback: true
            )
        )

        manager.refreshState(settings: delayedSettings)

        await pollUntil(timeout: 3.0) {
            delayedSettings.lastLicenseValidationDate != nil &&
            delayedSettings.lastLicenseValidationDate != now.addingTimeInterval(-300)
        }

        XCTAssertTrue(delayedSettings.isLicenseActivated)
        XCTAssertNotNil(delayedSettings.lastLicenseValidationDate)
        delayedDefaults.removePersistentDomain(forName: suiteName)
    }

    func testRevalidation_ambiguousResponseRetriesBeforeExpiry() async {
        let now = Date()
        let staleDate = now.addingTimeInterval(-120)
        settings.licenseKey = "VALID-KEY-1234"
        settings.updateLicenseEntitlement(makeTestEntitlement(
            validatedAt: staleDate,
            refreshAfter: staleDate,
            expiresAt: now.addingTimeInterval(0.5)
        ))

        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            if requestCount == 1 {
                let url = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (response, Data(repeating: 0x41, count: 1_000_001))
            }
            return try makeGumroadResponse(json: makeSuccessJSON())
        }

        license.refreshState(settings: settings)

        await pollUntil(timeout: 5.0) {
            requestCount >= 2 && (self.settings.lastLicenseValidationDate ?? .distantPast) > staleDate
        }

        XCTAssertGreaterThanOrEqual(requestCount, 2)
        XCTAssertTrue(settings.isLicenseActivated)
        XCTAssertEqual(license.activationState, .licensed)
    }
}
