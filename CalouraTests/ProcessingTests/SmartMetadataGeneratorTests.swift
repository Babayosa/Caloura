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

    // MARK: - parseResponse (deterministic)

    private let generator = SmartMetadataGenerator()

    func testParseResponse_validFormat() {
        let input = """
        FILENAME: cs101-lecture-notes
        SUMMARY: A lecture about data structures from CS 101
        TAGS: computer-science, lecture, data-structures
        """
        let result = generator.parseResponse(input)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.smartFileName, "cs101-lecture-notes")
        XCTAssertEqual(result?.summary, "A lecture about data structures from CS 101")
        XCTAssertEqual(result?.tags, ["computer-science", "lecture", "data-structures"])
    }

    func testParseResponse_emptyResponse_returnsNil() {
        XCTAssertNil(generator.parseResponse(""))
    }

    func testParseResponse_noMatchingFields_returnsNil() {
        XCTAssertNil(generator.parseResponse("This is just random text with no labels."))
    }

    func testParseResponse_partialFields() {
        let input = "SUMMARY: Just a summary, no filename or tags"
        let result = generator.parseResponse(input)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.smartFileName)
        XCTAssertEqual(result?.summary, "Just a summary, no filename or tags")
        XCTAssertTrue(result?.tags.isEmpty ?? true)
    }

    func testParseResponse_tagsLimitedToFive() {
        let input = "TAGS: a, b, c, d, e, f, g"
        let result = generator.parseResponse(input)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tags.count, 5)
    }

    func testParseResponse_summaryTruncatedAt200() {
        let longSummary = String(repeating: "x", count: 300)
        let input = "SUMMARY: \(longSummary)"
        let result = generator.parseResponse(input)
        XCTAssertEqual(result?.summary?.count, 200)
    }

    func testParseResponse_tagsLowercased() {
        let input = "TAGS: Swift, MacOS, XCode"
        let result = generator.parseResponse(input)
        XCTAssertEqual(result?.tags, ["swift", "macos", "xcode"])
    }

    func testParseResponse_extraWhitespace() {
        let input = """
          FILENAME:   some-file-name
          SUMMARY:   Some summary here
          TAGS:  tag1 ,  tag2 , tag3
        """
        let result = generator.parseResponse(input)
        XCTAssertEqual(result?.smartFileName, "some-file-name")
        XCTAssertEqual(result?.summary, "Some summary here")
        XCTAssertEqual(result?.tags, ["tag1", "tag2", "tag3"])
    }
}
