import XCTest
@testable import Caloura

final class ProcessedScreenshotTests: XCTestCase {

    private func makeScreenshot(
        appName: String? = nil,
        windowTitle: String? = nil,
        fileName: String = ""
    ) -> ProcessedScreenshot {
        let cgImage = TestImageFactory.makeTestImage(width: 50, height: 50)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 50, height: 50))
        let context = CaptureContext(
            mode: .area,
            sourceAppName: appName,
            sourceWindowTitle: windowTitle
        )
        return ProcessedScreenshot(
            image: nsImage,
            cgImage: cgImage,
            context: context,
            fileName: fileName
        )
    }

    // MARK: - toScreenshotItem title fallback

    func testToScreenshotItem_usesWindowTitle_whenAvailable() {
        let screenshot = makeScreenshot(appName: "Safari", windowTitle: "Apple.com")
        let item = screenshot.toScreenshotItem()
        XCTAssertEqual(item.title, "Apple.com")
    }

    func testToScreenshotItem_fallsBackToAppName_whenNoWindowTitle() {
        let screenshot = makeScreenshot(appName: "Safari", windowTitle: nil)
        let item = screenshot.toScreenshotItem()
        XCTAssertEqual(item.title, "Safari")
    }

    func testToScreenshotItem_fallsBackToUntitled_whenNeitherPresent() {
        let screenshot = makeScreenshot(appName: nil, windowTitle: nil)
        let item = screenshot.toScreenshotItem()
        XCTAssertEqual(item.title, "Untitled")
    }

    // MARK: - Image data

    func testPngData_returnsNonEmptyData() throws {
        let screenshot = makeScreenshot()
        let data = try screenshot.pngData()
        XCTAssertFalse(data.isEmpty)
        // PNG magic bytes
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50)
    }

    func testReleaseEncodedCaches_clearsPngBuffer() throws {
        let screenshot = makeScreenshot()
        _ = try screenshot.pngData()
        XCTAssertNotNil(screenshot.cachedPNGData())
        screenshot.releaseEncodedCaches()
        XCTAssertNil(screenshot.cachedPNGData())
    }

    func testReleaseEncodedCaches_isIdempotent() throws {
        let screenshot = makeScreenshot()
        screenshot.releaseEncodedCaches()
        screenshot.releaseEncodedCaches()
        XCTAssertNil(screenshot.cachedPNGData())
    }

    func testPngData_isCached() throws {
        let screenshot = makeScreenshot()
        let first = try screenshot.pngData()
        let second = try screenshot.pngData()
        XCTAssertEqual(first, second)
        XCTAssertNotNil(screenshot.cachedPNGData())
    }

    // MARK: - Dimensions

    func testDimensions_matchCGImage() {
        let cgImage = TestImageFactory.makeTestImage(width: 320, height: 240)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 320, height: 240))
        let screenshot = ProcessedScreenshot(
            image: nsImage,
            cgImage: cgImage,
            context: CaptureContext(mode: .fullscreen)
        )
        XCTAssertEqual(screenshot.width, 320)
        XCTAssertEqual(screenshot.height, 240)
    }
}
