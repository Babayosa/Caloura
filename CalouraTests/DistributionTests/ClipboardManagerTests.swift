import XCTest
@testable import Caloura

@MainActor
final class ClipboardManagerTests: XCTestCase {

    private let pasteboard = NSPasteboard.general

    // MARK: - Helpers

    private func makeScreenshot(
        width: Int = 100,
        height: Int = 100
    ) -> ProcessedScreenshot {
        let cgImage = TestImageFactory.makeTestImage(width: width, height: height)
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: width, height: height)
        )
        let context = CaptureContext(mode: .area, sourceAppName: "TestApp")
        return ProcessedScreenshot(
            image: nsImage,
            cgImage: cgImage,
            context: context,
            fileName: "test.png"
        )
    }

    // MARK: - copyImage

    func testCopyImage_putsTIFFDataOnPasteboard() async {
        let screenshot = makeScreenshot()

        await ClipboardManager.copyImage(screenshot)

        let tiffData = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(tiffData, "Pasteboard should contain TIFF data after copyImage")
        XCTAssertFalse(tiffData!.isEmpty, "TIFF data should not be empty")
    }

    func testCopyImage_putsPNGDataOnPasteboard() async {
        let screenshot = makeScreenshot()

        await ClipboardManager.copyImage(screenshot)

        let pngData = pasteboard.data(forType: .png)
        XCTAssertNotNil(pngData, "Pasteboard should contain PNG data after copyImage")
        XCTAssertFalse(pngData!.isEmpty, "PNG data should not be empty")
        // Verify PNG magic bytes
        XCTAssertEqual(pngData![0], 0x89)
        XCTAssertEqual(pngData![1], 0x50) // 'P'
        XCTAssertEqual(pngData![2], 0x4E) // 'N'
        XCTAssertEqual(pngData![3], 0x47) // 'G'
    }

    func testCopyImage_clearsPasteboardBeforeWriting() async {
        // Put some dummy data on the pasteboard first
        pasteboard.clearContents()
        pasteboard.setString("pre-existing data", forType: .string)
        let changeCountBefore = pasteboard.changeCount

        let screenshot = makeScreenshot()
        await ClipboardManager.copyImage(screenshot)

        // changeCount increments on clearContents, proving the pasteboard was cleared
        XCTAssertGreaterThan(
            pasteboard.changeCount,
            changeCountBefore,
            "Pasteboard changeCount should increment after copyImage (clearContents was called)"
        )
        // The pre-existing string type should be gone (cleared before writing image types)
        let stringData = pasteboard.string(forType: .string)
        XCTAssertNil(
            stringData,
            "Pre-existing string should be cleared after copyImage"
        )
    }

    // MARK: - copyMultiFormat

    func testCopyMultiFormat_setsTIFFData() async {
        let screenshot = makeScreenshot()

        await ClipboardManager.copyMultiFormat(screenshot)

        let tiffData = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(tiffData, "Pasteboard should contain TIFF data after copyMultiFormat")
        XCTAssertFalse(tiffData!.isEmpty)
    }

    func testCopyMultiFormat_setsPNGData() async {
        let screenshot = makeScreenshot()

        await ClipboardManager.copyMultiFormat(screenshot)

        let pngData = pasteboard.data(forType: .png)
        XCTAssertNotNil(pngData, "Pasteboard should contain PNG data after copyMultiFormat")
        XCTAssertFalse(pngData!.isEmpty)
    }

    func testCopyMultiFormat_setsStringData() async {
        let screenshot = makeScreenshot()

        await ClipboardManager.copyMultiFormat(screenshot)

        let stringData = pasteboard.string(forType: .string)
        XCTAssertNotNil(
            stringData,
            "Pasteboard should contain string (Markdown) data after copyMultiFormat"
        )
        XCTAssertFalse(stringData!.isEmpty)
        // Markdown format: ![Screenshot from TestApp](test.png)
        XCTAssertTrue(
            stringData!.contains("test.png"),
            "Markdown string should reference the file name"
        )
    }

    func testCopyMultiFormat_setsHTMLData() async {
        let screenshot = makeScreenshot()

        await ClipboardManager.copyMultiFormat(screenshot)

        let htmlData = pasteboard.data(forType: .html)
        XCTAssertNotNil(htmlData, "Pasteboard should contain HTML data after copyMultiFormat")
        let html = String(data: htmlData!, encoding: .utf8)
        XCTAssertNotNil(html)
        XCTAssertTrue(html!.contains("<img"), "HTML should contain an img tag")
    }

    func testCopyMultiFormat_allFourTypesSimultaneously() async {
        let screenshot = makeScreenshot()

        await ClipboardManager.copyMultiFormat(screenshot)

        // All four types should be present at the same time
        XCTAssertNotNil(pasteboard.data(forType: .tiff), "TIFF should be present")
        XCTAssertNotNil(pasteboard.data(forType: .png), "PNG should be present")
        XCTAssertNotNil(pasteboard.string(forType: .string), "String should be present")
        XCTAssertNotNil(pasteboard.data(forType: .html), "HTML should be present")
    }

    // MARK: - copyOCRText

    func testCopyOCRText_setsStringOnPasteboard() {
        ClipboardManager.copyOCRText("Hello, world!")

        let result = pasteboard.string(forType: .string)
        XCTAssertEqual(result, "Hello, world!")
    }

    func testCopyOCRText_emptyString_handlesGracefully() {
        ClipboardManager.copyOCRText("")

        let result = pasteboard.string(forType: .string)
        XCTAssertEqual(result, "")
    }

    func testCopyOCRText_clearsPreviousContent() {
        // Pre-fill with image data
        pasteboard.clearContents()
        pasteboard.setData(Data([0xFF]), forType: .tiff)

        ClipboardManager.copyOCRText("Some text")

        // TIFF should be gone after copyOCRText clears and writes string
        XCTAssertNil(
            pasteboard.data(forType: .tiff),
            "Previous TIFF data should be cleared"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "Some text")
    }

    // MARK: - copyAsMarkdown

    func testCopyAsMarkdown_setsMarkdownString() {
        let screenshot = makeScreenshot()

        ClipboardManager.copyAsMarkdown(screenshot)

        let result = pasteboard.string(forType: .string)
        XCTAssertNotNil(result)
        XCTAssertTrue(
            result!.contains("!["),
            "Should contain Markdown image syntax"
        )
        XCTAssertTrue(result!.contains("test.png"))
    }

    // MARK: - Small / edge-case images

    func testCopyImage_smallImage_handlesGracefully() async {
        let screenshot = makeScreenshot(width: 1, height: 1)

        await ClipboardManager.copyImage(screenshot)

        // Should still put data on pasteboard without crashing
        let tiffData = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(tiffData, "Even a 1x1 image should produce TIFF data")
    }
}
