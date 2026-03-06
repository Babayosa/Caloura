import XCTest
@testable import Caloura

final class PIIDetectorEdgeCaseTests: XCTestCase {

    func testLuhnCheck_validMastercard() {
        XCTAssertTrue(PIIDetector.luhnCheck("5500000000000004"))
    }

    func testLuhnCheck_validAmex() {
        XCTAssertTrue(PIIDetector.luhnCheck("378282246310005"))
    }

    func testLuhnCheck_allZeros() {
        // 0000000000000000 — Luhn passes on all zeros (sum=0, 0%10==0)
        // But it's 16 digits of zeros — valid Luhn technically
        XCTAssertTrue(PIIDetector.luhnCheck("0000000000000000"))
    }

    func testMask_shortEmail() {
        let masked = PIIDetector.mask("a@b.co", type: .email)
        XCTAssertEqual(masked, "a***@b.co")
    }

    func testMask_shortPhone() {
        let masked = PIIDetector.mask("1234", type: .phone)
        XCTAssertEqual(masked, "***-***-1234")
    }

    func testDetect_observations_keepsDuplicateMatchesAtDifferentLocations() {
        let text = "Reach us at same@example.com or same@example.com"
        let firstRange = text.range(of: "same@example.com")!
        let secondRange = text.range(of: "same@example.com", range: firstRange.upperBound..<text.endIndex)!
        let firstBox = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let secondBox = CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.1)

        let detections = PIIDetector.detect(in: [
            PIIDetectorObservation(
                text: text,
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.2),
                confidence: 0.99,
                matchBoundingBox: { range in
                    if range == firstRange { return firstBox }
                    if range == secondRange { return secondBox }
                    return nil
                }
            )
        ], types: [.email])

        XCTAssertEqual(detections.count, 2)
        assertRect(detections[0].boundingBox, equals: firstBox)
        assertRect(detections[1].boundingBox, equals: secondBox)
    }

    func testDetect_observations_usesPerMatchBoundingBoxInsteadOfWholeObservation() {
        let text = "prefix token_sk12345678901234567890 suffix"
        let matchBox = CGRect(x: 0.35, y: 0.2, width: 0.18, height: 0.08)
        let observationBox = CGRect(x: 0.05, y: 0.1, width: 0.9, height: 0.2)

        let detections = PIIDetector.detect(in: [
            PIIDetectorObservation(
                text: text,
                boundingBox: observationBox,
                confidence: 0.88,
                matchBoundingBox: { _ in matchBox }
            )
        ], types: [.apiKey])

        XCTAssertEqual(detections.count, 1)
        assertRect(detections[0].boundingBox, equals: matchBox)
        XCTAssertNotEqual(detections[0].boundingBox, observationBox)
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect, accuracy: CGFloat = 0.000_001) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: accuracy)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: accuracy)
        XCTAssertEqual(actual.size.width, expected.size.width, accuracy: accuracy)
        XCTAssertEqual(actual.size.height, expected.size.height, accuracy: accuracy)
    }
}
