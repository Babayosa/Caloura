import XCTest
@testable import Caloura

final class OCREngineTests: XCTestCase {

    /// A small solid black image should produce empty or whitespace-only OCR text.
    /// Note: Vision requires images > 2px in each dimension, so we use 10x10.
    func testRecognizeText_smallBlackImage_returnsEmptyString() async throws {
        let image = TestImageFactory.makeSolidColorImage(width: 10, height: 10, r: 0, g: 0, b: 0)
        let text = try await OCREngine.recognizeText(in: image)
        XCTAssertTrue(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "OCR on a small black image should return empty text, got: '\(text)'"
        )
    }

    /// A larger solid black image should also produce no text.
    func testRecognizeText_solidBlackImage_returnsEmptyString() async throws {
        let image = TestImageFactory.makeSolidColorImage(width: 100, height: 100, r: 0, g: 0, b: 0)
        let text = try await OCREngine.recognizeText(in: image)
        XCTAssertTrue(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "OCR on a solid black image should return empty text"
        )
    }

}
