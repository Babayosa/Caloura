import XCTest
@testable import Caloura

final class MarkdownExporterTests: XCTestCase {

    func testMarkdownImageTag_withAppName() {
        let screenshot = makeScreenshot(appName: "Safari", fileName: "screenshot.png")
        let result = MarkdownExporter.markdownImageTag(for: screenshot)
        XCTAssertEqual(result, "![Screenshot from Safari](screenshot.png)")
    }

    func testMarkdownImageTag_withoutAppName() {
        let screenshot = makeScreenshot(appName: nil, fileName: "test.png")
        let result = MarkdownExporter.markdownImageTag(for: screenshot)
        XCTAssertEqual(result, "![Screenshot](test.png)")
    }

    func testMarkdownWithCitation() {
        let date = makeDate(year: 2026, month: 1, day: 30, hour: 14, minute: 30)
        let screenshot = makeScreenshot(
            appName: "Chrome",
            windowTitle: "CS 101 Lecture",
            fileName: "lecture.png",
            timestamp: date
        )
        let result = MarkdownExporter.markdownWithCitation(for: screenshot)

        XCTAssertTrue(result.contains("![Screenshot from Chrome](lecture.png)"))
        XCTAssertTrue(result.contains("*Source: Chrome -- CS 101 Lecture"))
        XCTAssertTrue(result.contains("Jan 30, 2026"))
    }

    func testHtmlImageTag() {
        let screenshot = makeScreenshot(appName: "Safari", fileName: "test.png")
        let result = MarkdownExporter.htmlImageTag(for: screenshot)

        XCTAssertTrue(result.contains("<img"))
        XCTAssertTrue(result.contains("src=\"test.png\""))
        XCTAssertTrue(result.contains("alt=\"Screenshot from Safari\""))
    }

    // MARK: - Helpers

    private func makeScreenshot(
        appName: String? = nil,
        windowTitle: String? = nil,
        fileName: String = "screenshot.png",
        timestamp: Date = Date()
    ) -> ProcessedScreenshot {
        let context = CaptureContext(
            mode: .area,
            sourceAppName: appName,
            sourceWindowTitle: windowTitle,
            timestamp: timestamp
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let cgContext = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        let cgImage = cgContext.makeImage()!
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))

        let screenshot = ProcessedScreenshot(
            image: nsImage,
            cgImage: cgImage,
            pngData: Data(),
            context: context,
            fileName: fileName
        )
        return screenshot
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
}
