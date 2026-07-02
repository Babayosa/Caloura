import XCTest
@testable import Caloura

@MainActor
final class CaptureShareItemsTests: XCTestCase {

    // MARK: - ProcessedScreenshot

    func testProcessedScreenshot_savedPrefersFileURL() {
        let screenshot = CapturePipelineTestHelpers.makeProcessed()
        let url = URL(fileURLWithPath: "/tmp/example.png")
        screenshot.filePath = url

        let items = CaptureShareItems.items(for: screenshot)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first as? URL, url)
    }

    func testProcessedScreenshot_unsavedFallsBackToImage() {
        let screenshot = CapturePipelineTestHelpers.makeProcessed()
        XCTAssertNil(screenshot.filePath)

        let items = CaptureShareItems.items(for: screenshot)

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first is NSImage)
        XCTAssertIdentical(items.first as? NSImage, screenshot.image)
    }

    // MARK: - ScreenshotItem

    func testScreenshotItem_withPathReturnsFileURL() {
        let item = ScreenshotItem(
            filePath: "/tmp/history.png",
            fileName: "history.png",
            sourceAppName: nil,
            sourceWindowTitle: nil,
            captureMode: "area",
            width: 100,
            height: 100
        )

        let items = CaptureShareItems.items(for: item)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first as? URL, URL(fileURLWithPath: "/tmp/history.png"))
    }

    func testScreenshotItem_emptyPathReturnsNothing() {
        let item = ScreenshotItem(
            filePath: "",
            fileName: "unsaved.png",
            sourceAppName: nil,
            sourceWindowTitle: nil,
            captureMode: "area",
            width: 100,
            height: 100
        )

        XCTAssertTrue(CaptureShareItems.items(for: item).isEmpty)
    }
}
