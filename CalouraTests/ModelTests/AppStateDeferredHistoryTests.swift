import Foundation
import XCTest
@testable import Caloura

@MainActor
final class AppStateDeferredHistoryTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!
    nonisolated(unsafe) private var historyFileURL: URL!

    override nonisolated func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-history-tests-\(UUID().uuidString)")
        historyFileURL = tempRoot.appendingPathComponent("history.enc")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        HistoryCrypto.setSecurityDirectoryForTesting(tempRoot.appendingPathComponent("security"))
        HistoryCrypto.resetCachedKeyForTesting()
    }

    override nonisolated func tearDown() {
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
        AppStateTestHelpers.makeItem(fileName: name, height: 80)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        await pollUntil(timeout: timeout, predicate)
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

    func testMigratesEncryptedDefaultsHistoryToFileStorage() async throws {
        let defaults = makeDefaults(#function)
        let item = makeItem("defaults-encrypted.png")
        let json = try JSONEncoder().encode([item])
        let encrypted = try HistoryCrypto.encrypt(json)
        defaults.set(encrypted, forKey: "screenshotHistoryEncrypted")

        let state = AppState(defaults: defaults, historyStoreURL: historyFileURL)

        XCTAssertEqual(state.recentScreenshots.count, 1)
        XCTAssertEqual(state.recentScreenshots.first?.fileName, "defaults-encrypted.png")

        await waitUntil {
            FileManager.default.fileExists(atPath: self.historyFileURL.path) &&
            defaults.object(forKey: "screenshotHistoryEncrypted") == nil
        }
    }

    func testMigratesLegacyPlainHistoryToEncryptedFileStorage() async throws {
        let defaults = makeDefaults(#function)
        let item = makeItem("legacy-plain.png")
        let json = try JSONEncoder().encode([item])
        defaults.set(json, forKey: "screenshotHistory")

        let state = AppState(defaults: defaults, historyStoreURL: historyFileURL)

        XCTAssertEqual(state.recentScreenshots.count, 1)
        XCTAssertEqual(state.recentScreenshots.first?.fileName, "legacy-plain.png")

        await waitUntil {
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

    func testSaveHistoryNow_persistsLatestSnapshot() async throws {
        let defaults = makeDefaults(#function)
        let state = AppState(defaults: defaults, historyStoreURL: historyFileURL)

        state.addScreenshot(makeItem("first.png"))
        state.saveHistoryNow()
        state.addScreenshot(makeItem("second.png"))
        state.saveHistoryNow()

        await waitUntil {
            guard let decrypted = try? HistoryCrypto.readEncrypted(from: self.historyFileURL),
                  let items = try? JSONDecoder().decode([ScreenshotItem].self, from: decrypted) else {
                return false
            }
            return items.count == 2 && items.first?.fileName == "second.png"
        }
    }
}
