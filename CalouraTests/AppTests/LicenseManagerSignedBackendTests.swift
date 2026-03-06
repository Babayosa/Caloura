import CryptoKit
import XCTest
@testable import Caloura

private final class SignedEntitlementURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "license.caloura.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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

private func makeSignedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SignedEntitlementURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeEntitlementEnvelope(
    claims: LicenseEntitlementClaims,
    privateKey: Curve25519.Signing.PrivateKey
) throws -> Data {
    let payload = try JSONEncoder().encode(claims)
    let signature = try privateKey.signature(for: payload)
    let token = "\(base64URL(payload)).\(base64URL(signature))"
    return try JSONEncoder().encode(["token": token])
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

final class LicenseManagerSignedBackendTests: XCTestCase {
    private var settings: AppSettings!
    private var defaultsSuite: String!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(SignedEntitlementURLProtocol.self)
        defaultsSuite = "com.caloura.tests.license.signed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        settings = MainActor.assumeIsolated {
            let settings = AppSettings(defaults: defaults)
            settings.licenseKey = ""
            settings.updateLicenseEntitlement(nil)
            settings.lastLicenseValidationDate = nil
            return settings
        }
    }

    override func tearDown() {
        SignedEntitlementURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(SignedEntitlementURLProtocol.self)
        if let defaultsSuite {
            UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        }
        settings = nil
        defaultsSuite = nil
        super.tearDown()
    }

    @MainActor
    func testActivate_signedEntitlementSuccess_setsLicensed() async throws {
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = LicenseVerificationConfiguration(
            entitlementServiceURL: URL(string: "https://license.caloura.test/verify")!,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            requiresSignedEntitlement: true,
            allowGumroadFallback: false
        )
        let claims = LicenseEntitlementClaims(
            productID: "bmokl",
            licenseID: "signed-license",
            issuedAt: now.addingTimeInterval(-60),
            refreshAfter: now.addingTimeInterval(3_600),
            expiresAt: now.addingTimeInterval(86_400),
            featureFlags: ["pro": true]
        )
        SignedEntitlementURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, try makeEntitlementEnvelope(claims: claims, privateKey: privateKey))
        }

        let manager = LicenseManager(
            settings: settings,
            session: makeSignedSession(),
            now: { now },
            verificationConfiguration: configuration
        )

        await manager.activate(licenseKey: "SIGNED-KEY", settings: settings)

        XCTAssertEqual(manager.activationState, .licensed)
        XCTAssertEqual(settings.currentLicenseEntitlement?.source, .signedBackend)
        XCTAssertEqual(settings.currentLicenseEntitlement?.claims.licenseID, "signed-license")
        XCTAssertTrue(settings.isLicenseActivated)
    }

    @MainActor
    func testActivate_signedEntitlementWrongKey_fails() async throws {
        let now = Date()
        let signingKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let configuration = LicenseVerificationConfiguration(
            entitlementServiceURL: URL(string: "https://license.caloura.test/verify")!,
            entitlementPublicKeyBase64: wrongKey.publicKey.rawRepresentation.base64EncodedString(),
            requiresSignedEntitlement: true,
            allowGumroadFallback: false
        )
        let claims = LicenseEntitlementClaims(
            productID: "bmokl",
            licenseID: "signed-license",
            issuedAt: now.addingTimeInterval(-60),
            refreshAfter: now.addingTimeInterval(3_600),
            expiresAt: now.addingTimeInterval(86_400),
            featureFlags: [:]
        )
        SignedEntitlementURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, try makeEntitlementEnvelope(claims: claims, privateKey: signingKey))
        }

        let manager = LicenseManager(
            settings: settings,
            session: makeSignedSession(),
            now: { now },
            verificationConfiguration: configuration
        )

        await manager.activate(licenseKey: "SIGNED-KEY", settings: settings)

        guard case .activationFailed = manager.activationState else {
            return XCTFail("Expected activationFailed, got \(manager.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
        XCTAssertNil(settings.currentLicenseEntitlement)
    }

    @MainActor
    func testActivate_signedEntitlementExpired_fails() async throws {
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = LicenseVerificationConfiguration(
            entitlementServiceURL: URL(string: "https://license.caloura.test/verify")!,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            requiresSignedEntitlement: true,
            allowGumroadFallback: false
        )
        let claims = LicenseEntitlementClaims(
            productID: "bmokl",
            licenseID: "expired-license",
            issuedAt: now.addingTimeInterval(-1_000),
            refreshAfter: now.addingTimeInterval(-500),
            expiresAt: now.addingTimeInterval(-1),
            featureFlags: [:]
        )
        SignedEntitlementURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, try makeEntitlementEnvelope(claims: claims, privateKey: privateKey))
        }

        let manager = LicenseManager(
            settings: settings,
            session: makeSignedSession(),
            now: { now },
            verificationConfiguration: configuration
        )

        await manager.activate(licenseKey: "SIGNED-KEY", settings: settings)

        guard case .activationFailed = manager.activationState else {
            return XCTFail("Expected activationFailed, got \(manager.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    @MainActor
    func testActivate_signedEntitlementWrongProduct_fails() async throws {
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = LicenseVerificationConfiguration(
            entitlementServiceURL: URL(string: "https://license.caloura.test/verify")!,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            requiresSignedEntitlement: true,
            allowGumroadFallback: false
        )
        let claims = LicenseEntitlementClaims(
            productID: "wrong-product",
            licenseID: "wrong-product-license",
            issuedAt: now.addingTimeInterval(-60),
            refreshAfter: now.addingTimeInterval(3_600),
            expiresAt: now.addingTimeInterval(86_400),
            featureFlags: [:]
        )
        SignedEntitlementURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, try makeEntitlementEnvelope(claims: claims, privateKey: privateKey))
        }

        let manager = LicenseManager(
            settings: settings,
            session: makeSignedSession(),
            now: { now },
            verificationConfiguration: configuration
        )

        await manager.activate(licenseKey: "SIGNED-KEY", settings: settings)

        guard case .activationFailed = manager.activationState else {
            return XCTFail("Expected activationFailed, got \(manager.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }

    @MainActor
    func testActivate_releaseRequiresSignedEntitlementWithoutBackendConfig_fails() async {
        let manager = LicenseManager(
            settings: settings,
            session: makeSignedSession(),
            verificationConfiguration: LicenseVerificationConfiguration(
                entitlementServiceURL: nil,
                entitlementPublicKeyBase64: nil,
                requiresSignedEntitlement: true,
                allowGumroadFallback: false
            )
        )

        await manager.activate(licenseKey: "SIGNED-KEY", settings: settings)

        guard case .activationFailed = manager.activationState else {
            return XCTFail("Expected activationFailed, got \(manager.activationState)")
        }
        XCTAssertFalse(settings.isLicenseActivated)
    }
}
