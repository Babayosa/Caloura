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
}
