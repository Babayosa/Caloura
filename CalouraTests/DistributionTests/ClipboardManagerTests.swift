import XCTest
@testable import Caloura

@MainActor
final class ClipboardManagerTests: XCTestCase {

    nonisolated(unsafe) private var testPasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.caloura.test.\(UUID().uuidString)"))
        self.testPasteboard = pasteboard
        MainActor.assumeIsolated {
            ClipboardManager.pasteboardOverride = pasteboard
        }
    }

    override func tearDown() {
        let pasteboard: NSPasteboard = testPasteboard
        MainActor.assumeIsolated {
            ClipboardManager.pasteboardOverride = nil
        }
        pasteboard.releaseGlobally()
        testPasteboard = nil
        super.tearDown()
    }

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

    func testCopyImage_putsTIFFDataOnPasteboard() async throws {
        let screenshot = makeScreenshot()

        try await ClipboardManager.copyImage(screenshot)

        let tiffData = testPasteboard.data(forType: .tiff)
        XCTAssertNotNil(tiffData, "Pasteboard should contain TIFF data after copyImage")
        XCTAssertFalse(tiffData!.isEmpty, "TIFF data should not be empty")
    }

    func testCopyImage_putsPNGDataOnPasteboard() async throws {
        let screenshot = makeScreenshot()

        try await ClipboardManager.copyImage(screenshot)

        let pngData = testPasteboard.data(forType: .png)
        XCTAssertNotNil(pngData, "Pasteboard should contain PNG data after copyImage")
        XCTAssertFalse(pngData!.isEmpty, "PNG data should not be empty")
        // Verify PNG magic bytes
        XCTAssertEqual(pngData![0], 0x89)
        XCTAssertEqual(pngData![1], 0x50) // 'P'
        XCTAssertEqual(pngData![2], 0x4E) // 'N'
        XCTAssertEqual(pngData![3], 0x47) // 'G'
    }

    func testCopyImage_clearsPasteboardBeforeWriting() async throws {
        // Put some dummy data on the pasteboard first
        testPasteboard.clearContents()
        testPasteboard.setString("pre-existing data", forType: .string)
        let changeCountBefore = testPasteboard.changeCount

        let screenshot = makeScreenshot()
        try await ClipboardManager.copyImage(screenshot)

        // changeCount increments on clearContents, proving the pasteboard was cleared
        XCTAssertGreaterThan(
            testPasteboard.changeCount,
            changeCountBefore,
            "Pasteboard changeCount should increment after copyImage (clearContents was called)"
        )
        // The pre-existing string type should be gone (cleared before writing image types)
        let stringData = testPasteboard.string(forType: .string)
        XCTAssertNil(
            stringData,
            "Pre-existing string should be cleared after copyImage"
        )
    }

    // MARK: - copyMultiFormat

    func testCopyMultiFormat_setsTIFFData() async throws {
        let screenshot = makeScreenshot()

        try await ClipboardManager.copyMultiFormat(screenshot)

        let tiffData = testPasteboard.data(forType: .tiff)
        XCTAssertNotNil(tiffData, "Pasteboard should contain TIFF data after copyMultiFormat")
        XCTAssertFalse(tiffData!.isEmpty)
    }

    func testCopyMultiFormat_setsPNGData() async throws {
        let screenshot = makeScreenshot()

        try await ClipboardManager.copyMultiFormat(screenshot)

        let pngData = testPasteboard.data(forType: .png)
        XCTAssertNotNil(pngData, "Pasteboard should contain PNG data after copyMultiFormat")
        XCTAssertFalse(pngData!.isEmpty)
    }

    func testCopyMultiFormat_setsStringData() async throws {
        let screenshot = makeScreenshot()

        try await ClipboardManager.copyMultiFormat(screenshot)

        let stringData = testPasteboard.string(forType: .string)
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

    func testCopyMultiFormat_setsHTMLData() async throws {
        let screenshot = makeScreenshot()

        try await ClipboardManager.copyMultiFormat(screenshot)

        let htmlData = testPasteboard.data(forType: .html)
        XCTAssertNotNil(htmlData, "Pasteboard should contain HTML data after copyMultiFormat")
        let html = String(data: htmlData!, encoding: .utf8)
        XCTAssertNotNil(html)
        XCTAssertTrue(html!.contains("<img"), "HTML should contain an img tag")
    }

    func testCopyMultiFormat_allFourTypesSimultaneously() async throws {
        let screenshot = makeScreenshot()

        try await ClipboardManager.copyMultiFormat(screenshot)

        // All four types should be present at the same time
        XCTAssertNotNil(testPasteboard.data(forType: .tiff), "TIFF should be present")
        XCTAssertNotNil(testPasteboard.data(forType: .png), "PNG should be present")
        XCTAssertNotNil(testPasteboard.string(forType: .string), "String should be present")
        XCTAssertNotNil(testPasteboard.data(forType: .html), "HTML should be present")
    }

    // MARK: - copyOCRText

    func testCopyOCRText_setsStringOnPasteboard() throws {
        try ClipboardManager.copyOCRText("Hello, world!")

        let result = testPasteboard.string(forType: .string)
        XCTAssertEqual(result, "Hello, world!")
    }

    func testCopyOCRText_emptyString_handlesGracefully() throws {
        try ClipboardManager.copyOCRText("")

        let result = testPasteboard.string(forType: .string)
        XCTAssertEqual(result, "")
    }

    func testCopyOCRText_clearsPreviousContent() throws {
        // Pre-fill with image data
        testPasteboard.clearContents()
        testPasteboard.setData(Data([0xFF]), forType: .tiff)

        try ClipboardManager.copyOCRText("Some text")

        // TIFF should be gone after copyOCRText clears and writes string
        XCTAssertNil(
            testPasteboard.data(forType: .tiff),
            "Previous TIFF data should be cleared"
        )
        XCTAssertEqual(testPasteboard.string(forType: .string), "Some text")
    }

    // MARK: - copyAsMarkdown

    func testCopyAsMarkdown_setsMarkdownString() throws {
        let screenshot = makeScreenshot()

        try ClipboardManager.copyAsMarkdown(screenshot)

        let result = testPasteboard.string(forType: .string)
        XCTAssertNotNil(result)
        XCTAssertTrue(
            result!.contains("!["),
            "Should contain Markdown image syntax"
        )
        XCTAssertTrue(result!.contains("test.png"))
    }

    // MARK: - copyNSImage

    func testCopyNSImage_writesImageToPasteboard() throws {
        let cgImage = TestImageFactory.makeTestImage(width: 50, height: 50)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 50, height: 50))

        try ClipboardManager.copyNSImage(nsImage)

        let objects = testPasteboard.readObjects(forClasses: [NSImage.self])
        XCTAssertNotNil(objects)
        XCTAssertEqual(objects?.count, 1)
    }

    // MARK: - Small / edge-case images

    func testCopyImage_smallImage_handlesGracefully() async throws {
        let screenshot = makeScreenshot(width: 1, height: 1)

        try await ClipboardManager.copyImage(screenshot)

        // Should still put data on pasteboard without crashing
        let tiffData = testPasteboard.data(forType: .tiff)
        XCTAssertNotNil(tiffData, "Even a 1x1 image should produce TIFF data")
    }
}
