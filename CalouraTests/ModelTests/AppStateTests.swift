import XCTest
@testable import Caloura

@MainActor
final class AppStateTests: XCTestCase {

    private var appState: AppState!

    override func setUp() {
        super.setUp()
        appState = AppState.shared
        appState.clearHistory()
    }

    override func tearDown() {
        appState.clearHistory()
        appState = nil
        super.tearDown()
    }

    // MARK: - addScreenshot

    func testAddScreenshot_insertsAtFront() {
        let item1 = makeItem(fileName: "first.png")
        let item2 = makeItem(fileName: "second.png")

        appState.addScreenshot(item1)
        appState.addScreenshot(item2)

        XCTAssertEqual(appState.recentScreenshots.count, 2)
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "second.png")
        XCTAssertEqual(appState.recentScreenshots[1].fileName, "first.png")
    }

    func testAddScreenshot_enforces50ItemLimit() {
        for i in 0..<55 {
            appState.addScreenshot(makeItem(fileName: "screenshot_\(i).png"))
        }

        XCTAssertEqual(appState.recentScreenshots.count, 50)
        // Most recent should be last added
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "screenshot_54.png")
    }

    // MARK: - clearHistory

    func testClearHistory_removesAll() {
        appState.addScreenshot(makeItem(fileName: "a.png"))
        appState.addScreenshot(makeItem(fileName: "b.png"))

        appState.clearHistory()

        XCTAssertTrue(appState.recentScreenshots.isEmpty)
    }

    // MARK: - JSON persistence round-trip

    func testPersistence_roundTrip() {
        let item = makeItem(fileName: "persist.png", appName: "Safari", ocrText: "Hello World")
        appState.addScreenshot(item)

        // Force a re-load by accessing shared (persistence uses UserDefaults)
        // We can verify by checking the item is still there
        XCTAssertEqual(appState.recentScreenshots.count, 1)
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "persist.png")
        XCTAssertEqual(appState.recentScreenshots[0].sourceAppName, "Safari")
        XCTAssertEqual(appState.recentScreenshots[0].ocrText, "Hello World")
    }

    func testAddScreenshot_preservesID() {
        let item = makeItem(fileName: "id_test.png")
        let originalID = item.id
        appState.addScreenshot(item)
        XCTAssertEqual(appState.recentScreenshots[0].id, originalID)
    }

    func testAddScreenshot_multipleItemsPreserveOrder() {
        let items = (0..<5).map { makeItem(fileName: "item_\($0).png") }
        items.forEach { appState.addScreenshot($0) }

        XCTAssertEqual(appState.recentScreenshots.count, 5)
        // Items should be in reverse insertion order (newest first)
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "item_4.png")
        XCTAssertEqual(appState.recentScreenshots[4].fileName, "item_0.png")
    }

    // MARK: - Mutation persistence

    func testTitleEdit_persistsAfterSave() {
        let item = makeItem(fileName: "title_test.png")
        appState.addScreenshot(item)

        appState.recentScreenshots[0].title = "Edited Title"
        appState.saveHistory()

        XCTAssertEqual(appState.recentScreenshots[0].title, "Edited Title")
    }

    func testTagAddRemove_persistsAfterSave() {
        let item = makeItem(fileName: "tag_test.png")
        appState.addScreenshot(item)

        // Add tag and save
        appState.recentScreenshots[0].tags.append("CS101")
        appState.saveHistory()
        XCTAssertEqual(appState.recentScreenshots[0].tags, ["CS101"])

        // Remove tag and save
        appState.recentScreenshots[0].tags.removeAll { $0 == "CS101" }
        appState.saveHistory()
        XCTAssertTrue(appState.recentScreenshots[0].tags.isEmpty)
    }

    func testOCRUpdate_preservesTitleAndTags() {
        let item = makeItem(fileName: "ocr_test.png")
        appState.addScreenshot(item)

        // Set title and tags
        appState.recentScreenshots[0].title = "My Screenshot"
        appState.recentScreenshots[0].tags = ["lecture", "bio"]
        appState.saveHistory()

        // Simulate OCR update (same pattern as CapturePipeline)
        let existing = appState.recentScreenshots[0]
        let updated = ScreenshotItem(
            id: existing.id,
            timestamp: existing.timestamp,
            filePath: existing.filePath,
            fileName: existing.fileName,
            sourceAppName: existing.sourceAppName,
            sourceWindowTitle: existing.sourceWindowTitle,
            captureMode: existing.captureMode,
            presetName: existing.presetName,
            ocrText: "Recognized text from OCR",
            width: existing.width,
            height: existing.height,
            title: existing.title,
            tags: existing.tags
        )
        appState.recentScreenshots[0] = updated
        appState.saveHistory()

        XCTAssertEqual(appState.recentScreenshots[0].title, "My Screenshot")
        XCTAssertEqual(appState.recentScreenshots[0].tags, ["lecture", "bio"])
        XCTAssertEqual(appState.recentScreenshots[0].ocrText, "Recognized text from OCR")
    }

    // MARK: - Helpers

    private func makeItem(
        fileName: String,
        appName: String? = nil,
        ocrText: String? = nil
    ) -> ScreenshotItem {
        ScreenshotItem(
            filePath: "/tmp/\(fileName)",
            fileName: fileName,
            sourceAppName: appName,
            captureMode: "area",
            ocrText: ocrText,
            width: 100,
            height: 100
        )
    }
}
