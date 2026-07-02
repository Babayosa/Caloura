import CryptoKit
import os.log
import XCTest
@testable import Caloura

/// Direct unit tests for `LicenseEntitlementVerifier` negative paths that the
/// manager-level suites never reach (audit L10):
///  1. a signed-backend response whose URL host differs from the configured
///     backend host must be rejected as ambiguous (guard at
///     `LicenseEntitlementVerifier.swift:69`), even when the body is otherwise
///     a perfectly valid, correctly-signed entitlement.
///  2. a token whose signature bytes are tampered — verified against the
///     *correct* public key — must fail signature validation and surface as
///     ambiguous, not as a valid entitlement.
///
/// Both tests pair the failure case with a positive control using the identical
/// body/key so the only variable is the defect under test.
private final class VerifierURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "license.caloura.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private func makeVerifierSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VerifierURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func makeEnvelope(
    claims: LicenseEntitlementClaims,
    privateKey: Curve25519.Signing.PrivateKey,
    tamperSignature: Bool = false
) throws -> Data {
    let payload = try JSONEncoder().encode(claims)
    var signatureBytes = Array(try privateKey.signature(for: payload))
    if tamperSignature {
        // Flip one bit so the signature no longer verifies against the correct key.
        signatureBytes[0] ^= 0xFF
    }
    let token = "\(base64URL(payload)).\(base64URL(Data(signatureBytes)))"
    return try JSONEncoder().encode(["token": token])
}

final class LicenseEntitlementVerifierTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(VerifierURLProtocol.self)
    }

    override func tearDown() {
        VerifierURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(VerifierURLProtocol.self)
        super.tearDown()
    }

    private func makeValidClaims(now: Date) -> LicenseEntitlementClaims {
        LicenseEntitlementClaims(
            productID: LicenseEntitlementVerifier.gumroadProductID,
            licenseID: "signed-license",
            issuedAt: now.addingTimeInterval(-60),
            refreshAfter: now.addingTimeInterval(3_600),
            expiresAt: now.addingTimeInterval(86_400),
            featureFlags: ["pro": true]
        )
    }

    private func makeVerifier(
        publicKeyBase64: String,
        now: Date
    ) -> LicenseEntitlementVerifier {
        LicenseEntitlementVerifier(
            session: makeVerifierSession(),
            now: { now },
            configuration: LicenseVerificationConfiguration(
                entitlementServiceURL: URL(string: "https://license.caloura.test/verify")!,
                entitlementPublicKeyBase64: publicKeyBase64,
                requiresSignedEntitlement: true,
                allowGumroadFallback: false
            ),
            logger: Logger(subsystem: "com.caloura.tests", category: "verifier")
        )
    }

    /// A response arriving from a different host than the configured backend
    /// must be rejected as ambiguous even though the signed body is valid —
    /// the host guard trips before the signature is trusted.
    func testVerify_responseHostMismatch_returnsAmbiguous() async throws {
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let claims = makeValidClaims(now: now)
        let body = try makeEnvelope(claims: claims, privateKey: privateKey)
        let verifier = makeVerifier(
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            now: now
        )

        // Positive control: identical body from the CONFIGURED host validates.
        VerifierURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        guard case .valid = await verifier.verify(key: "SIGNED-KEY", existingEntitlement: nil) else {
            return XCTFail("Control: matching-host response with a valid body must be .valid")
        }

        // Same valid body, but the response URL reports a foreign host.
        VerifierURLProtocol.requestHandler = { _ in
            let foreignURL = URL(string: "https://attacker.example.com/verify")!
            return (HTTPURLResponse(url: foreignURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        guard case .ambiguousResponse = await verifier.verify(key: "SIGNED-KEY", existingEntitlement: nil) else {
            return XCTFail("Host-mismatched response must be rejected as .ambiguousResponse")
        }
    }

    /// A token whose signature bytes are corrupted must fail signature
    /// validation against the correct public key and surface as ambiguous —
    /// never as a valid entitlement.
    func testVerify_tamperedSignatureWithCorrectKey_returnsAmbiguous() async throws {
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let claims = makeValidClaims(now: now)
        let verifier = makeVerifier(
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            now: now
        )

        // Positive control: the untampered token from the same key validates.
        let validBody = try makeEnvelope(claims: claims, privateKey: privateKey)
        VerifierURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, validBody)
        }
        guard case .valid = await verifier.verify(key: "SIGNED-KEY", existingEntitlement: nil) else {
            return XCTFail("Control: an untampered token from the correct key must be .valid")
        }

        // Tampered signature, correct key → signature check fails → ambiguous.
        let tamperedBody = try makeEnvelope(claims: claims, privateKey: privateKey, tamperSignature: true)
        VerifierURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, tamperedBody)
        }
        guard case .ambiguousResponse = await verifier.verify(key: "SIGNED-KEY", existingEntitlement: nil) else {
            return XCTFail("A tampered signature must be rejected as .ambiguousResponse")
        }
    }
}
