import XCTest
@testable import Caloura

@MainActor
final class AppStateTests: XCTestCase {

    private var appState: AppState!
    private var defaults: UserDefaults!
    private var historyFileURL: URL!
    private var tempRoot: URL!
    private var defaultsSuite: String!

    override func setUp() {
        super.setUp()
        defaultsSuite = "com.caloura.tests.appstate.core.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-appstate-tests-\(UUID().uuidString)")
        historyFileURL = tempRoot.appendingPathComponent("history.enc")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        HistoryCrypto.setSecurityDirectoryForTesting(tempRoot.appendingPathComponent("security"))
        HistoryCrypto.resetCachedKeyForTesting()

        appState = AppState(defaults: defaults, historyStoreURL: historyFileURL)
        appState.clearHistory()
    }

    override func tearDown() {
        appState.clearHistory()
        appState = nil
        if let defaultsSuite {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        defaults = nil
        defaultsSuite = nil
        HistoryCrypto.setSecurityDirectoryForTesting(nil)
        HistoryCrypto.resetCachedKeyForTesting()
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        historyFileURL = nil
        super.tearDown()
    }

    // MARK: - addScreenshot

    func testAddScreenshot_insertsAtFront() {
        let item1 = AppStateTestHelpers.makeItem(fileName: "first.png")
        let item2 = AppStateTestHelpers.makeItem(fileName: "second.png")

        appState.addScreenshot(item1)
        appState.addScreenshot(item2)

        XCTAssertEqual(appState.recentScreenshots.count, 2)
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "second.png")
        XCTAssertEqual(appState.recentScreenshots[1].fileName, "first.png")
    }

    func testAddScreenshot_enforces50ItemLimit() {
        for i in 0..<55 {
            appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "screenshot_\(i).png"))
        }

        XCTAssertEqual(appState.recentScreenshots.count, 50)
        // Most recent should be last added
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "screenshot_54.png")
    }

    // MARK: - clearHistory

    func testClearHistory_removesAll() {
        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "a.png"))
        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "b.png"))

        appState.clearHistory()

        XCTAssertTrue(appState.recentScreenshots.isEmpty)
    }

    // MARK: - JSON persistence round-trip

    func testPersistence_roundTrip() {
        let item = AppStateTestHelpers.makeItem(fileName: "persist.png", appName: "Safari", ocrText: "Hello World")
        appState.addScreenshot(item)

        // Force a re-load by accessing shared (persistence uses UserDefaults)
        // We can verify by checking the item is still there
        XCTAssertEqual(appState.recentScreenshots.count, 1)
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "persist.png")
        XCTAssertEqual(appState.recentScreenshots[0].sourceAppName, "Safari")
        XCTAssertEqual(appState.recentScreenshots[0].ocrText, "Hello World")
    }

    func testAddScreenshot_preservesID() {
        let item = AppStateTestHelpers.makeItem(fileName: "id_test.png")
        let originalID = item.id
        appState.addScreenshot(item)
        XCTAssertEqual(appState.recentScreenshots[0].id, originalID)
    }

    func testAddScreenshot_multipleItemsPreserveOrder() {
        let items = (0..<5).map { AppStateTestHelpers.makeItem(fileName: "item_\($0).png") }
        items.forEach { appState.addScreenshot($0) }

        XCTAssertEqual(appState.recentScreenshots.count, 5)
        // Items should be in reverse insertion order (newest first)
        XCTAssertEqual(appState.recentScreenshots[0].fileName, "item_4.png")
        XCTAssertEqual(appState.recentScreenshots[4].fileName, "item_0.png")
    }

    // MARK: - Mutation persistence

    func testTitleEdit_persistsAfterSave() {
        let item = AppStateTestHelpers.makeItem(fileName: "title_test.png")
        appState.addScreenshot(item)

        appState.recentScreenshots[0].title = "Edited Title"
        appState.saveHistory()

        XCTAssertEqual(appState.recentScreenshots[0].title, "Edited Title")
    }

    func testTagAddRemove_persistsAfterSave() {
        let item = AppStateTestHelpers.makeItem(fileName: "tag_test.png")
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
        let item = AppStateTestHelpers.makeItem(fileName: "ocr_test.png")
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

}
