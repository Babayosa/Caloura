import Foundation
import XCTest
@testable import Caloura

@MainActor
final class AppStateDeferredHistoryTests: XCTestCase {
    private var tempRoot: URL!
    private var historyFileURL: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-history-tests-\(UUID().uuidString)")
        historyFileURL = tempRoot.appendingPathComponent("history.enc")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        HistoryCrypto.setSecurityDirectoryForTesting(tempRoot.appendingPathComponent("security"))
        HistoryCrypto.resetCachedKeyForTesting()
    }

    override func tearDown() {
        HistoryCrypto.setSecurityDirectoryForTesting(nil)
        HistoryCrypto.resetCachedKeyForTesting()
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeDefaults(_ testName: String) -> UserDefaults {
        let suite = "com.caloura.tests.appstate.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeItem(_ name: String) -> ScreenshotItem {
        ScreenshotItem(
            filePath: "/tmp/\(name)",
            fileName: name,
            captureMode: "area",
            width: 100,
            height: 80
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ predicate: @escaping () -> Bool
    ) {
        let expectation = XCTestExpectation(description: "Wait for condition")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if predicate() {
                timer.invalidate()
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: timeout)
        timer.invalidate()
    }

    func testLoadsFileBackedEncryptedHistoryAtStartup() throws {
        let defaults = makeDefaults(#function)
        let item = makeItem("file-backed.png")
        let json = try JSONEncoder().encode([item])
        let encrypted = try HistoryCrypto.encrypt(json)
        try encrypted.write(to: historyFileURL, options: .atomic)

        let state = AppState(defaults: defaults, historyStoreURL: historyFileURL)

        XCTAssertEqual(state.recentScreenshots.count, 1)
        XCTAssertEqual(state.recentScreenshots.first?.fileName, "file-backed.png")
    }

    func testMigratesEncryptedDefaultsHistoryToFileStorage() throws {
        let defaults = makeDefaults(#function)
        let item = makeItem("defaults-encrypted.png")
        let json = try JSONEncoder().encode([item])
        let encrypted = try HistoryCrypto.encrypt(json)
        defaults.set(encrypted, forKey: "screenshotHistoryEncrypted")

        let state = AppState(defaults: defaults, historyStoreURL: historyFileURL)

        XCTAssertEqual(state.recentScreenshots.count, 1)
        XCTAssertEqual(state.recentScreenshots.first?.fileName, "defaults-encrypted.png")

        waitUntil {
            FileManager.default.fileExists(atPath: self.historyFileURL.path) &&
            defaults.object(forKey: "screenshotHistoryEncrypted") == nil
        }
    }

    func testMigratesLegacyPlainHistoryToEncryptedFileStorage() throws {
        let defaults = makeDefaults(#function)
        let item = makeItem("legacy-plain.png")
        let json = try JSONEncoder().encode([item])
        defaults.set(json, forKey: "screenshotHistory")

        let state = AppState(defaults: defaults, historyStoreURL: historyFileURL)

        XCTAssertEqual(state.recentScreenshots.count, 1)
        XCTAssertEqual(state.recentScreenshots.first?.fileName, "legacy-plain.png")

        waitUntil {
            FileManager.default.fileExists(atPath: self.historyFileURL.path) &&
            defaults.object(forKey: "screenshotHistory") == nil
        }
    }

    func testFileBackedHistoryPurgesAnyDefaultsBackups() throws {
        let defaults = makeDefaults(#function)
        let fileItem = makeItem("file-backed.png")
        let fileJSON = try JSONEncoder().encode([fileItem])
        let encryptedFile = try HistoryCrypto.encrypt(fileJSON)
        try encryptedFile.write(to: historyFileURL, options: .atomic)

        let encryptedDefaultsItem = makeItem("defaults-encrypted.png")
        let encryptedDefaultsJSON = try JSONEncoder().encode([encryptedDefaultsItem])
        let encryptedDefaultsBlob = try HistoryCrypto.encrypt(encryptedDefaultsJSON)
        defaults.set(encryptedDefaultsBlob, forKey: "screenshotHistoryEncrypted")

        let legacyDefaultsItem = makeItem("legacy-plain.png")
        let legacyDefaultsJSON = try JSONEncoder().encode([legacyDefaultsItem])
        defaults.set(legacyDefaultsJSON, forKey: "screenshotHistory")

        let state = AppState(defaults: defaults, historyStoreURL: historyFileURL)

        XCTAssertEqual(state.recentScreenshots.count, 1)
        XCTAssertEqual(state.recentScreenshots.first?.fileName, "file-backed.png")
        XCTAssertNil(defaults.object(forKey: "screenshotHistoryEncrypted"))
        XCTAssertNil(defaults.object(forKey: "screenshotHistory"))
    }
}
