import AppKit
import os.log
import SwiftUI

private let appStateLogger = Logger(subsystem: "com.caloura.app", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var recentScreenshots: [ScreenshotItem] = []
    @Published var lastScreenshot: ProcessedScreenshot? {
        didSet { resetLastScreenshotTimer() }
    }
    @Published var isCapturing: Bool = false
    @Published var hasScreenRecordingPermission: Bool = false
    @Published var statusMessage: String = ""
    @Published var isCountingDown: Bool = false
    @Published var countdownRemaining: Int = 0

    /// Stores the last area capture rect for the repeat capture feature.
    @Published var lastCaptureRect: CGRect?
    /// Stores the screen used for the last area capture.
    /// Not @Published — NSScreen is not Equatable and no SwiftUI view reads this directly.
    var lastCaptureScreen: NSScreen?

    @Published var lastPIIResult: PIIDetectionResult?

    let embeddingStore = EmbeddingStore()

    private let maxRecentItems = 50
    private let historyDefaultsKey = "screenshotHistoryEncrypted"
    private let legacyHistoryDefaultsKey = "screenshotHistory"
    private let defaults: UserDefaults
    private let historyFileURL: URL

    // Debounce save operations to avoid hammering disk writes.
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 500_000_000 // 500ms
    private var lastScreenshotTimer: Timer?

    init(defaults: UserDefaults = .standard, historyStoreURL: URL? = nil) {
        self.defaults = defaults
        self.historyFileURL = historyStoreURL ?? Self.defaultHistoryFileURL()
        loadHistory()
        embeddingStore.load()
        auditStoragePermissions()
    }

    func addScreenshot(_ item: ScreenshotItem) {
        recentScreenshots.insert(item, at: 0)
        if recentScreenshots.count > maxRecentItems {
            recentScreenshots.removeLast(recentScreenshots.count - maxRecentItems)
        }
        debouncedSaveHistory()
    }

    func clearHistory() {
        recentScreenshots.removeAll()
        embeddingStore.clear()
        saveHistoryNow()
    }

    /// Schedule a debounced save (coalesces rapid changes).
    private func debouncedSaveHistory() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: saveDebounceInterval)
            guard !Task.isCancelled else { return }
            saveHistoryNow()
        }
    }

    /// Immediately persist history (called by debounce timer or clearHistory).
    func saveHistory() {
        debouncedSaveHistory()
    }

    /// Force immediate save without debouncing.
    func saveHistoryNow() {
        saveTask?.cancel()
        saveTask = nil

        // Copy array to avoid data races on detached thread.
        let itemsCopy = Array(recentScreenshots)
        let historyFileURL = self.historyFileURL
        let defaults = self.defaults
        let historyDefaultsKey = self.historyDefaultsKey
        let legacyHistoryDefaultsKey = self.legacyHistoryDefaultsKey

        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(itemsCopy)
                let encrypted = try HistoryCrypto.encrypt(data)
                let directoryURL = historyFileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try encrypted.write(to: historyFileURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: historyFileURL.path
                )

                // Migration cleanup: once file-backed persistence succeeds,
                // remove legacy defaults blobs.
                Self.purgeHistoryDefaults(
                    in: defaults,
                    historyDefaultsKey: historyDefaultsKey,
                    legacyHistoryDefaultsKey: legacyHistoryDefaultsKey
                )
            } catch {
                appStateLogger.error("Failed to persist screenshot history: \(error.localizedDescription)")
            }
        }
    }

    private static func defaultHistoryFileURL() -> URL {
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Caloura/history.enc")
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return fallback
        }
        return appSupport.appendingPathComponent("Caloura").appendingPathComponent("history.enc")
    }

    private func loadHistory() {
        if let encryptedFileData = try? Data(contentsOf: historyFileURL) {
            do {
                let decrypted = try HistoryCrypto.decrypt(encryptedFileData)
                if let result = decodeHistory(from: decrypted, source: "file") {
                    purgeLegacyHistoryDefaults()
                    recentScreenshots = result.items
                    if result.recovered {
                        saveHistoryNow()
                    }
                    return
                }
            } catch {
                let desc = error.localizedDescription
                appStateLogger.error(
                    "Failed to decrypt file-backed screenshot history: \(desc)"
                )
            }
        }

        if let encryptedDefaultsData = defaults.data(forKey: historyDefaultsKey) {
            defaults.removeObject(forKey: historyDefaultsKey)
            do {
                let decrypted = try HistoryCrypto.decrypt(encryptedDefaultsData)
                if let result = decodeHistory(from: decrypted, source: "defaults-encrypted") {
                    recentScreenshots = result.items
                    saveHistoryNow()
                    return
                }
            } catch {
                let desc = error.localizedDescription
                appStateLogger.error(
                    "Failed to decrypt defaults-backed screenshot history: \(desc)"
                )
            }
        }

        guard let legacyData = defaults.data(forKey: legacyHistoryDefaultsKey) else {
            return
        }
        // Remove plaintext history blob immediately after loading into memory.
        defaults.removeObject(forKey: legacyHistoryDefaultsKey)

        if let result = decodeHistory(from: legacyData, source: "defaults-legacy") {
            recentScreenshots = result.items
            saveHistoryNow()
        }
    }

    private struct HistoryLoadResult {
        let items: [ScreenshotItem]
        let recovered: Bool
    }

    private func decodeHistory(from data: Data, source: String) -> HistoryLoadResult? {
        do {
            let items = try JSONDecoder().decode([ScreenshotItem].self, from: data)
            return HistoryLoadResult(items: items, recovered: false)
        } catch {
            let desc = error.localizedDescription
            let errMsg = "Failed to decode \(source) screenshot history:"
                + " \(desc). Attempting partial recovery."
            appStateLogger.error("\(errMsg)")
            // Attempt to recover individual items from the array.
            if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var recovered: [ScreenshotItem] = []
                for element in jsonArray {
                    if let elementData = try? JSONSerialization.data(withJSONObject: element),
                       let item = try? JSONDecoder().decode(ScreenshotItem.self, from: elementData) {
                        recovered.append(item)
                    }
                }
                appStateLogger.info("Recovered \(recovered.count) of \(jsonArray.count) history items")
                return HistoryLoadResult(items: recovered, recovered: true)
            }
        }
        return nil
    }

    private func auditStoragePermissions() {
        let warnings = HistoryCrypto.auditStoragePermissions(historyFileURL: historyFileURL)
        if warnings.isEmpty {
            appStateLogger.debug("History storage permission audit passed.")
            return
        }
        for warning in warnings {
            appStateLogger.warning("\(warning, privacy: .public)")
        }
    }

    private func resetLastScreenshotTimer() {
        lastScreenshotTimer?.invalidate()
        lastScreenshotTimer = nil
        guard lastScreenshot != nil else { return }
        lastScreenshotTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastScreenshot = nil
            }
        }
    }

    private func purgeLegacyHistoryDefaults() {
        Self.purgeHistoryDefaults(
            in: defaults,
            historyDefaultsKey: historyDefaultsKey,
            legacyHistoryDefaultsKey: legacyHistoryDefaultsKey
        )
    }

    nonisolated private static func purgeHistoryDefaults(
        in defaults: UserDefaults,
        historyDefaultsKey: String,
        legacyHistoryDefaultsKey: String
    ) {
        defaults.removeObject(forKey: historyDefaultsKey)
        defaults.removeObject(forKey: legacyHistoryDefaultsKey)
    }
}
