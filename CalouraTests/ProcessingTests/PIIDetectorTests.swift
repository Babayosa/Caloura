import XCTest
@testable import Caloura

final class PIIDetectorTests: XCTestCase {

    // MARK: - Luhn Check

    func testLuhnCheck_validVisa() {
        XCTAssertTrue(PIIDetector.luhnCheck("4111111111111111"))
    }

    func testLuhnCheck_validVisaWithSpaces() {
        XCTAssertTrue(PIIDetector.luhnCheck("4111 1111 1111 1111"))
    }

    func testLuhnCheck_invalidNumber() {
        XCTAssertFalse(PIIDetector.luhnCheck("1234567890123456"))
    }

    func testLuhnCheck_tooShort() {
        XCTAssertFalse(PIIDetector.luhnCheck("123456"))
    }

    // MARK: - Masking

    func testMask_email() {
        let masked = PIIDetector.mask("user@example.com", type: .email)
        XCTAssertEqual(masked, "u***@example.com")
    }

    func testMask_phone() {
        let masked = PIIDetector.mask("555-123-4567", type: .phone)
        XCTAssertEqual(masked, "***-***-4567")
    }

    func testMask_creditCard() {
        let masked = PIIDetector.mask("4111 1111 1111 1111", type: .creditCard)
        XCTAssertEqual(masked, "****-****-****-1111")
    }

    func testMask_ssn() {
        let masked = PIIDetector.mask("123-45-6789", type: .ssn)
        XCTAssertEqual(masked, "***-**-****")
    }

    func testMask_apiKey() {
        let masked = PIIDetector.mask("sk-abcdef1234567890abcdef", type: .apiKey)
        XCTAssertTrue(masked.contains("***"))
    }

    // MARK: - Empty image detection

    func testDetect_emptyImage_noDetections() async throws {
        let image = TestImageFactory.makeSolidColorImage(width: 10, height: 10, r: 0, g: 0, b: 0)
        let detections = try await PIIDetector.detect(in: image)
        XCTAssertTrue(detections.isEmpty)
    }

    // MARK: - Regex Pattern Matching

    func testDetectInText_email() {
        let results = PIIDetector.detectInText("Contact us at user@example.com for info")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .email)
        XCTAssertEqual(results.first?.match, "user@example.com")
    }

    func testDetectInText_phone_formats() {
        let texts = [
            "555-123-4567",
            "555.123.4567",
            "+1-555-123-4567",
            "5551234567"
        ]
        for text in texts {
            let results = PIIDetector.detectInText(text, types: [.phone])
            XCTAssertFalse(results.isEmpty, "Should detect phone in: \(text)")
        }
    }

    func testDetectInText_creditCard_validLuhn() {
        let results = PIIDetector.detectInText(
            "Card: 4111 1111 1111 1111",
            types: [.creditCard]
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .creditCard)
    }

    func testDetectInText_creditCard_invalidLuhn_noMatch() {
        let results = PIIDetector.detectInText(
            "Number: 1234 5678 9012 3456",
            types: [.creditCard]
        )
        XCTAssertTrue(results.isEmpty, "Invalid Luhn should not match")
    }

    func testDetectInText_apiKey() {
        let results = PIIDetector.detectInText(
            "Key: sk-abc123def456ghi789jkl012",
            types: [.apiKey]
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .apiKey)
    }

    func testDetectInText_ipAddress_valid() {
        let results = PIIDetector.detectInText(
            "Server at 192.168.1.1 is down",
            types: [.ipAddress]
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.match, "192.168.1.1")
    }

    func testDetectInText_ipAddress_invalidOctets() {
        let results = PIIDetector.detectInText(
            "Value 999.999.999.999",
            types: [.ipAddress]
        )
        XCTAssertTrue(results.isEmpty, "Invalid IP octets should not match")
    }

    func testDetectInText_ssn() {
        let results = PIIDetector.detectInText(
            "SSN: 123-45-6789",
            types: [.ssn]
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .ssn)
    }

    func testDetectInText_multipleTypes() {
        let text = "Email user@test.com and call 555-123-4567"
        let results = PIIDetector.detectInText(text)
        let types = Set(results.map(\.type))
        XCTAssertTrue(types.contains(.email))
        XCTAssertTrue(types.contains(.phone))
    }

    func testDetectInText_noMatch() {
        let results = PIIDetector.detectInText("Hello world, nothing sensitive here")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Raw text never stored on PIIDetection.text

    /// Regression: PIIDetection used to store the raw matched string. Any code
    /// that read `.text` (logging, exports, future serialization) leaked the
    /// PII verbatim. Contract is now: `.text` is masked at construction.
    func testPIIDetectionStoresMaskedTextNotRaw() {
        let cases: [(PIIType, String)] = [
            (.email, "user@example.com"),
            (.phone, "555-123-4567"),
            (.creditCard, "4111 1111 1111 1111"),
            (.ssn, "123-45-6789"),
            (.apiKey, "token-abcdef1234567890abcdef"),
            (.ipAddress, "192.168.1.42")
        ]
        for (type, raw) in cases {
            let detection = PIIDetection(
                type: type,
                rawMatch: raw,
                boundingBox: .zero,
                confidence: 1
            )
            XCTAssertNotEqual(
                detection.text,
                raw,
                "\(type): .text must not equal raw input — masking failed"
            )
            XCTAssertEqual(
                detection.text,
                PIIDetector.mask(raw, type: type),
                "\(type): .text must equal mask(raw, type)"
            )
        }
    }

    /// Stronger guarantee for the most sensitive types: the masked string
    /// must contain no contiguous run of the raw match's body characters.
    func testPIIDetectionMaskedTextDoesNotContainRawBody() {
        let detection = PIIDetection(
            type: .ssn,
            rawMatch: "123-45-6789",
            boundingBox: .zero,
            confidence: 1
        )
        XCTAssertFalse(detection.text.contains("123"), "SSN area number must be masked")
        XCTAssertFalse(detection.text.contains("45"), "SSN group number must be masked")
        XCTAssertFalse(detection.text.contains("6789"), "SSN serial must be masked")
    }
}
