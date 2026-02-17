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
    chargebacked: Bool = false
) -> [String: Any] {
    [
        "success": true,
        "purchase": [
            "refunded": refunded,
            "disputed": disputed,
            "chargebacked": chargebacked,
            "email": "test@example.com"
        ]
    ]
}

// MARK: - Tests

@MainActor
final class LicenseManagerNetworkTests: XCTestCase {

    private var settings: AppSettings!
    private var license: LicenseManager!

    private var savedFirstLaunchDate: Date!
    private var savedLicenseKey: String!
    private var savedIsLicenseActivated: Bool!
    private var savedLastValidationDate: Date?

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)

        settings = AppSettings.shared

        // Save original values
        savedFirstLaunchDate = settings.firstLaunchDate
        savedLicenseKey = settings.licenseKey
        savedIsLicenseActivated = settings.isLicenseActivated
        savedLastValidationDate = settings.lastLicenseValidationDate

        // Reset to unlicensed state
        settings.licenseKey = ""
        settings.isLicenseActivated = false
        settings.lastLicenseValidationDate = nil

        license = LicenseManager(settings: settings)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)

        // Restore original values
        settings.firstLaunchDate = savedFirstLaunchDate
        settings.licenseKey = savedLicenseKey
        settings.isLicenseActivated = savedIsLicenseActivated
        settings.lastLicenseValidationDate = savedLastValidationDate
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
        settings.isLicenseActivated = true
        // Set validation date to 2 days ago to exceed revalidation interval (1 day)
        settings.lastLicenseValidationDate = Date().addingTimeInterval(-2 * 86_400)

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
        settings.isLicenseActivated = true
        settings.lastLicenseValidationDate = Date().addingTimeInterval(-2 * 86_400)

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
        settings.isLicenseActivated = true
        settings.lastLicenseValidationDate = Date().addingTimeInterval(-2 * 86_400)

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
        settings.isLicenseActivated = true
        settings.lastLicenseValidationDate = Date().addingTimeInterval(-2 * 86_400)

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
        settings.isLicenseActivated = true
        let staleDate = Date().addingTimeInterval(-2 * 86_400)
        settings.lastLicenseValidationDate = staleDate

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
}
