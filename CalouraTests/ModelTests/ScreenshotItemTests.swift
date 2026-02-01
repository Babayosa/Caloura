import XCTest
@testable import Caloura

final class ScreenshotItemTests: XCTestCase {

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let item = ScreenshotItem(
            filePath: "/tmp/test.png",
            fileName: "test.png",
            sourceAppName: "Safari",
            sourceWindowTitle: "Apple",
            captureMode: "area",
            presetName: "Quick Capture",
            ocrText: "Hello World",
            width: 1920,
            height: 1080
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScreenshotItem.self, from: data)

        XCTAssertEqual(decoded.id, item.id)
        XCTAssertEqual(decoded.filePath, item.filePath)
        XCTAssertEqual(decoded.fileName, item.fileName)
        XCTAssertEqual(decoded.sourceAppName, item.sourceAppName)
        XCTAssertEqual(decoded.sourceWindowTitle, item.sourceWindowTitle)
        XCTAssertEqual(decoded.captureMode, item.captureMode)
        XCTAssertEqual(decoded.presetName, item.presetName)
        XCTAssertEqual(decoded.ocrText, item.ocrText)
        XCTAssertEqual(decoded.width, item.width)
        XCTAssertEqual(decoded.height, item.height)
    }

    // MARK: - Hashable conformance

    func testHashable_sameIDsAreEqual() {
        let id = UUID()
        let item1 = ScreenshotItem(
            id: id,
            filePath: "/tmp/a.png",
            fileName: "a.png",
            captureMode: "area"
        )
        let item2 = ScreenshotItem(
            id: id,
            filePath: "/tmp/a.png",
            fileName: "a.png",
            captureMode: "area"
        )
        XCTAssertEqual(item1, item2)
        XCTAssertEqual(item1.hashValue, item2.hashValue)
    }

    func testHashable_differentIDsAreNotEqual() {
        let item1 = ScreenshotItem(
            filePath: "/tmp/a.png",
            fileName: "a.png",
            captureMode: "area"
        )
        let item2 = ScreenshotItem(
            filePath: "/tmp/a.png",
            fileName: "a.png",
            captureMode: "area"
        )
        XCTAssertNotEqual(item1, item2)
    }

    // MARK: - Missing field decode

    func testCodableRoundTrip_withTitleAndTags() throws {
        let item = ScreenshotItem(
            filePath: "/tmp/tagged.png",
            fileName: "tagged.png",
            sourceAppName: "Preview",
            captureMode: "area",
            width: 800,
            height: 600,
            title: "Lecture Slide 3",
            tags: ["CS101", "midterm", "diagrams"]
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScreenshotItem.self, from: data)

        XCTAssertEqual(decoded.id, item.id)
        XCTAssertEqual(decoded.title, "Lecture Slide 3")
        XCTAssertEqual(decoded.tags, ["CS101", "midterm", "diagrams"])
    }

    func testDecode_withoutTitleAndTags_defaultsApplied() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": Date().timeIntervalSinceReferenceDate,
            "filePath": "/tmp/notags.png",
            "fileName": "notags.png",
            "captureMode": "fullscreen",
            "width": 1920,
            "height": 1080
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ScreenshotItem.self, from: data)

        XCTAssertNil(decoded.title)
        XCTAssertEqual(decoded.tags, [])
    }

    func testDecode_withMinimalFields() throws {
        // Simulate JSON with only required fields; optional fields should default to nil
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": Date().timeIntervalSinceReferenceDate,
            "filePath": "/tmp/minimal.png",
            "fileName": "minimal.png",
            "captureMode": "fullscreen",
            "width": 0,
            "height": 0
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ScreenshotItem.self, from: data)

        XCTAssertEqual(decoded.fileName, "minimal.png")
        XCTAssertNil(decoded.sourceAppName)
        XCTAssertNil(decoded.sourceWindowTitle)
        XCTAssertNil(decoded.ocrText)
        XCTAssertNil(decoded.presetName)
    }
}
