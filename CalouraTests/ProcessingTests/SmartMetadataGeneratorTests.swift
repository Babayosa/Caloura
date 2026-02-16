import XCTest
@testable import Caloura

final class SmartMetadataGeneratorTests: XCTestCase {

    func testGenerate_emptyText_returnsNil() async {
        let result = await SmartMetadataGenerator.shared.generate(
            ocrText: "",
            sourceApp: nil,
            windowTitle: nil
        )
        XCTAssertNil(result)
    }

    func testGenerate_withOCRText_returnsMetadataOrNil() async {
        // On-device model may not be available in CI/test environments
        // This test verifies the method doesn't crash and returns a valid result or nil
        let result = await SmartMetadataGenerator.shared.generate(
            ocrText: "Professor Smith - CS 101 - Introduction to Data Structures",
            sourceApp: "Safari",
            windowTitle: "Lecture Notes"
        )
        // Either nil (model unavailable) or valid metadata
        if let result {
            if let fileName = result.smartFileName {
                XCTAssertLessThanOrEqual(fileName.count, 50)
                XCTAssertFalse(fileName.contains(" "), "Smart filename should not contain spaces")
            }
            if let summary = result.summary {
                XCTAssertLessThanOrEqual(summary.count, 200)
            }
            XCTAssertLessThanOrEqual(result.tags.count, 5)
        }
    }

    func testGenerate_veryLongOCR_doesNotCrash() async {
        let longText = String(repeating: "This is test content. ", count: 500)
        // Should not crash — internally truncates to 1000 chars
        _ = await SmartMetadataGenerator.shared.generate(
            ocrText: longText,
            sourceApp: "TextEdit",
            windowTitle: nil
        )
    }
}
