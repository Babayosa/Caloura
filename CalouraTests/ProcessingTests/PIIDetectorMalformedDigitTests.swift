import XCTest
@testable import Caloura

/// Non-ASCII Unicode digits (e.g. Thai) pass `Character.isWholeNumber` and are
/// matched by ICU `\d`, but `Int(String(_:))` cannot parse them. These inputs
/// must be rejected, never force-unwrapped.
final class PIIDetectorMalformedDigitTests: XCTestCase {

    func testLuhnCheck_nonASCIIDigits_returnsFalse() {
        let thaiDigits = String(repeating: "\u{0E54}", count: 16) // ๔ x16
        XCTAssertFalse(PIIDetector.luhnCheck(thaiDigits))
    }

    func testLuhnCheck_mixedASCIIAndNonASCIIDigits_returnsFalse() {
        let mixed = "411111111111111" + "\u{0E54}"
        XCTAssertFalse(PIIDetector.luhnCheck(mixed))
    }

    func testDetectInText_thaiDigitSSNCandidate_doesNotCrashAndYieldsNoSSN() {
        let text = "SSN \u{0E51}\u{0E52}\u{0E53}-\u{0E54}\u{0E55}-\u{0E56}\u{0E57}\u{0E58}\u{0E59}"
        let results = PIIDetector.detectInText(text, types: [.ssn])
        XCTAssertTrue(results.isEmpty, "non-ASCII digit SSN candidates must be rejected")
    }

    func testDetectInText_thaiDigitCreditCardCandidate_doesNotCrashAndYieldsNoCard() {
        let text = String(repeating: "\u{0E54}", count: 16)
        let results = PIIDetector.detectInText(text, types: [.creditCard])
        XCTAssertTrue(results.isEmpty, "non-ASCII digit card candidates must be rejected")
    }
}
