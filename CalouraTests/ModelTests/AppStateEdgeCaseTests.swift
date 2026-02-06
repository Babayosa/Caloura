import XCTest
@testable import Caloura

@MainActor
final class AppStateEdgeCaseTests: XCTestCase {

    private var appState: AppState!
    private var defaults: UserDefaults!
    private var historyFileURL: URL!
    private var tempRoot: URL!
    private var defaultsSuite: String!

    override func setUp() {
        super.setUp()
        defaultsSuite = "com.caloura.tests.appstate.edge.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "caloura-appstate-edge-tests-\(UUID().uuidString)"
            )
        historyFileURL = tempRoot.appendingPathComponent("history.enc")
        try? FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        HistoryCrypto.setSecurityDirectoryForTesting(
            tempRoot.appendingPathComponent("security")
        )
        HistoryCrypto.resetCachedKeyForTesting()

        appState = AppState(
            defaults: defaults,
            historyStoreURL: historyFileURL
        )
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

    // MARK: - Rapid sequential adds

    func testRapid100Adds_cappedAt50() {
        for i in 0..<100 {
            appState.addScreenshot(
                AppStateTestHelpers.makeItem(fileName: "rapid_\(i).png")
            )
        }

        XCTAssertEqual(appState.recentScreenshots.count, 50)
    }

    func testRapid100Adds_newestFirst() {
        for i in 0..<100 {
            appState.addScreenshot(
                AppStateTestHelpers.makeItem(fileName: "rapid_\(i).png")
            )
        }

        // Most recent (index 99) should be at front
        XCTAssertEqual(
            appState.recentScreenshots[0].fileName,
            "rapid_99.png"
        )
        // Oldest surviving item should be index 50 (items 0-49 evicted)
        XCTAssertEqual(
            appState.recentScreenshots[49].fileName,
            "rapid_50.png"
        )
    }

    func testRapid100Adds_orderIsCorrect() {
        for i in 0..<100 {
            appState.addScreenshot(
                AppStateTestHelpers.makeItem(fileName: "rapid_\(i).png")
            )
        }

        // Verify descending order across all 50 retained items
        for idx in 0..<50 {
            let expectedNumber = 99 - idx
            XCTAssertEqual(
                appState.recentScreenshots[idx].fileName,
                "rapid_\(expectedNumber).png",
                "Item at index \(idx) should be rapid_\(expectedNumber).png"
            )
        }
    }

    // MARK: - Save + reload after rapid adds

    func testPersistenceIntegrity_afterRapidAdds() async throws {
        for i in 0..<60 {
            appState.addScreenshot(
                AppStateTestHelpers.makeItem(fileName: "persist_\(i).png")
            )
        }

        XCTAssertEqual(appState.recentScreenshots.count, 50)

        // Force save and wait for debounce to settle
        appState.saveHistory()
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        // Reload into a fresh AppState using the same backing store
        let reloaded = AppState(
            defaults: defaults,
            historyStoreURL: historyFileURL
        )

        XCTAssertEqual(reloaded.recentScreenshots.count, 50)
        XCTAssertEqual(
            reloaded.recentScreenshots[0].fileName,
            "persist_59.png"
        )
        XCTAssertEqual(
            reloaded.recentScreenshots[49].fileName,
            "persist_10.png"
        )
    }

    // MARK: - Interleaved add + clear

    func testInterleavedAddClear_noStaleData() {
        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "a.png"))
        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "b.png"))
        XCTAssertEqual(appState.recentScreenshots.count, 2)

        appState.clearHistory()
        XCTAssertTrue(appState.recentScreenshots.isEmpty)

        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "c.png"))
        XCTAssertEqual(appState.recentScreenshots.count, 1)
        XCTAssertEqual(
            appState.recentScreenshots[0].fileName,
            "c.png"
        )
    }

    func testMultipleClearCycles_noStaleData() {
        for cycle in 0..<3 {
            for index in 0..<5 {
                appState.addScreenshot(
                    AppStateTestHelpers.makeItem(fileName: "cycle\(cycle)_\(index).png")
                )
            }
            appState.clearHistory()
            XCTAssertTrue(
                appState.recentScreenshots.isEmpty,
                "History should be empty after clear in cycle \(cycle)"
            )
        }

        // After all clears, add one more and verify no stale items
        appState.addScreenshot(AppStateTestHelpers.makeItem(fileName: "final.png"))
        XCTAssertEqual(appState.recentScreenshots.count, 1)
        XCTAssertEqual(
            appState.recentScreenshots[0].fileName,
            "final.png"
        )
    }

    func testClearThenRapidAdds_noStaleData() {
        for i in 0..<30 {
            appState.addScreenshot(
                AppStateTestHelpers.makeItem(fileName: "pre_clear_\(i).png")
            )
        }
        appState.clearHistory()

        for i in 0..<10 {
            appState.addScreenshot(
                AppStateTestHelpers.makeItem(fileName: "post_clear_\(i).png")
            )
        }

        XCTAssertEqual(appState.recentScreenshots.count, 10)
        // Verify none of the pre-clear items leaked through
        for item in appState.recentScreenshots {
            XCTAssertTrue(
                item.fileName.hasPrefix("post_clear_"),
                "Found stale item: \(item.fileName)"
            )
        }
    }

}
