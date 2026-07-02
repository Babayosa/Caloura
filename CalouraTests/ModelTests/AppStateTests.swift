import XCTest
@testable import Caloura

@MainActor
final class AppStateTests: XCTestCase {

    nonisolated(unsafe) private var appState: AppState!
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var historyFileURL: URL!
    nonisolated(unsafe) private var tempRoot: URL!
    nonisolated(unsafe) private var defaultsSuite: String!

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuite = "com.caloura.tests.appstate.core.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-appstate-tests-\(UUID().uuidString)")
        historyFileURL = tempRoot.appendingPathComponent("history.enc")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        HistoryCrypto.setSecurityDirectoryForTesting(tempRoot.appendingPathComponent("security"))
        HistoryCrypto.resetCachedKeyForTesting()

        let defaults = defaults!
        let historyFileURL = historyFileURL!
        let state = await MainActor.run {
            // Pin the retention cap so these tests are independent of the live
            // AppSettings.historyItemLimit default (200); 50 preserves the
            // semantics they were written against.
            AppState(defaults: defaults, historyStoreURL: historyFileURL, historyItemLimit: 50)
        }
        self.appState = state
        await MainActor.run {
            state.clearHistory()
        }
    }

    override func tearDown() async throws {
        let state = appState
        await MainActor.run {
            state?.clearHistory()
        }
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
        try await super.tearDown()
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

    // MARK: - setHistoryItemLimit (configurable retention cap)

    func testSetHistoryItemLimit_loweringPrunesItemsAndEmbeddings() async {
        var items: [ScreenshotItem] = []
        for i in 0..<30 {
            let item = AppStateTestHelpers.makeItem(fileName: "e\(i).png")
            items.append(item)
            await appState.embeddingStore.add(
                screenshotID: item.id,
                vector: [Double(i), 1, 0],
                textHash: "h\(i)"
            )
            appState.addScreenshot(item)
        }
        // Cap is 50, so 30 adds prune nothing.
        XCTAssertEqual(appState.recentScreenshots.count, 30)

        appState.setHistoryItemLimit(10)

        XCTAssertEqual(appState.recentScreenshots.count, 10)
        // Newest-first: e29 at front, oldest survivor is e20.
        XCTAssertEqual(appState.recentScreenshots.first?.fileName, "e29.png")
        XCTAssertEqual(appState.recentScreenshots.last?.fileName, "e20.png")

        let dropped = items.prefix(20).map(\.id)
        let kept = items.suffix(10).map(\.id)

        // Embedding removal is fire-and-forget (Task { await store.remove }).
        let allDroppedGone = await waitUntil {
            for id in dropped where await self.appState.embeddingStore.hasEmbedding(for: id) {
                return false
            }
            return true
        }
        XCTAssertTrue(allDroppedGone, "Pruned items' embeddings must be removed")

        for id in kept {
            let present = await appState.embeddingStore.hasEmbedding(for: id)
            XCTAssertTrue(present, "Kept items' embeddings must survive the prune")
        }
    }

    func testSetHistoryItemLimit_unlimitedNeverPrunes() {
        appState.setHistoryItemLimit(AppSettings.unlimitedHistoryLimit)
        for i in 0..<250 {
            appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "u\(i).png"))
        }
        XCTAssertEqual(appState.recentScreenshots.count, 250)
    }

    func testSetHistoryItemLimit_raisingKeepsExistingItems() {
        for i in 0..<50 {
            appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "r\(i).png"))
        }
        XCTAssertEqual(appState.recentScreenshots.count, 50)

        appState.setHistoryItemLimit(200)
        XCTAssertEqual(appState.recentScreenshots.count, 50)

        for i in 50..<60 {
            appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "r\(i).png"))
        }
        XCTAssertEqual(appState.recentScreenshots.count, 60)
    }

    /// Polls `condition` until it returns true or `timeout` elapses.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        return await condition()
    }

    // MARK: - clearHistory

    func testClearHistory_removesAll() {
        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "a.png"))
        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "b.png"))

        appState.clearHistory()

        XCTAssertTrue(appState.recentScreenshots.isEmpty)
    }

    func testPreviewPhase_isTrackedPerScreenshot() {
        let first = AppStateTestHelpers.makeItem(fileName: "first.png")
        let second = AppStateTestHelpers.makeItem(fileName: "second.png")
        appState.addScreenshot(first)
        appState.addScreenshot(second)

        appState.setCapturePreviewPhase(.enrichmentPending, for: first.id)
        appState.setCapturePreviewPhase(.enrichmentComplete, for: second.id)

        XCTAssertEqual(appState.previewPhase(for: first.id), .enrichmentPending)
        XCTAssertEqual(appState.previewPhase(for: second.id), .enrichmentComplete)
    }

    func testPIIResult_isTrackedPerScreenshot() {
        let first = AppStateTestHelpers.makeItem(fileName: "first.png")
        let second = AppStateTestHelpers.makeItem(fileName: "second.png")
        appState.addScreenshot(first)
        appState.addScreenshot(second)

        let firstResult = PIIDetectionResult(
            detections: [PIIDetection(type: .email, rawMatch: "one@example.com", boundingBox: .zero, confidence: 1)],
            screenshotID: first.id
        )
        let secondResult = PIIDetectionResult(
            detections: [PIIDetection(type: .email, rawMatch: "two@example.com", boundingBox: .zero, confidence: 1)],
            screenshotID: second.id
        )

        appState.setPIIResult(firstResult)
        appState.setPIIResult(secondResult)

        XCTAssertEqual(appState.piiResult(for: first.id)?.screenshotID, first.id)
        XCTAssertEqual(appState.piiResult(for: first.id)?.detections.first?.text, "o***@example.com")
        XCTAssertEqual(appState.piiResult(for: second.id)?.screenshotID, second.id)
        XCTAssertEqual(appState.piiResult(for: second.id)?.detections.first?.text, "t***@example.com")
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

        appState.renameScreenshot(id: item.id, title: "Edited Title")

        XCTAssertEqual(appState.recentScreenshots[0].title, "Edited Title")
    }

    func testTagAddRemove_persistsAfterSave() {
        let item = AppStateTestHelpers.makeItem(fileName: "tag_test.png")
        appState.addScreenshot(item)

        appState.addTag("CS101", to: item.id)
        XCTAssertEqual(appState.recentScreenshots[0].tags, ["CS101"])

        appState.removeTag("CS101", from: item.id)
        XCTAssertTrue(appState.recentScreenshots[0].tags.isEmpty)
    }

    func testOCRUpdate_preservesTitleAndTags() {
        let item = AppStateTestHelpers.makeItem(fileName: "ocr_test.png")
        appState.addScreenshot(item)

        appState.renameScreenshot(id: item.id, title: "My Screenshot")
        appState.addTag("lecture", to: item.id)
        appState.addTag("bio", to: item.id)
        appState.updateScreenshot(id: item.id) { storedItem in
            storedItem.ocrText = "Recognized text from OCR"
        }

        XCTAssertEqual(appState.recentScreenshots[0].title, "My Screenshot")
        XCTAssertEqual(appState.recentScreenshots[0].tags, ["lecture", "bio"])
        XCTAssertEqual(appState.recentScreenshots[0].ocrText, "Recognized text from OCR")
    }

    func testDeleteScreenshot_removesHistoryAndAssociatedState() {
        let item = AppStateTestHelpers.makeItem(fileName: "delete_test.png")
        appState.addScreenshot(item)
        appState.setCapturePreviewPhase(.enrichmentPending, for: item.id)
        appState.setPIIResult(
            PIIDetectionResult(
                detections: [PIIDetection(type: .email, rawMatch: "person@example.com", boundingBox: .zero, confidence: 1)],
                screenshotID: item.id
            )
        )

        appState.deleteScreenshot(id: item.id)

        XCTAssertTrue(appState.recentScreenshots.isEmpty)
        XCTAssertEqual(appState.previewPhase(for: item.id), .rawPreviewReady)
        XCTAssertNil(appState.piiResult(for: item.id))
    }

    func testApplyMetadata_updatesGeneratedFields() {
        let item = AppStateTestHelpers.makeItem(fileName: "metadata_test.png")
        appState.addScreenshot(item)

        appState.applyMetadata(
            ScreenshotMetadata(
                smartFileName: "meeting-notes",
                summary: "Screenshot of meeting notes.",
                tags: ["notes", "meeting"]
            ),
            to: item.id
        )

        XCTAssertEqual(appState.recentScreenshots[0].smartFileName, "meeting-notes")
        XCTAssertEqual(appState.recentScreenshots[0].summary, "Screenshot of meeting notes.")
        XCTAssertEqual(appState.recentScreenshots[0].autoTags, ["notes", "meeting"])
    }

    func testMarkEmbeddingVersion_updatesStoredItem() {
        let item = AppStateTestHelpers.makeItem(fileName: "embedding_test.png")
        appState.addScreenshot(item)

        appState.markEmbeddingVersion(3, for: item.id)

        XCTAssertEqual(appState.recentScreenshots[0].embeddingVersion, 3)
    }

}
