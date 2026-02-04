import AppKit
import Foundation
import os.log
import SwiftUI

private let appStateLogger = Logger(subsystem: "com.caloura.app", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var recentScreenshots: [ScreenshotItem] = []
    @Published var lastScreenshot: ProcessedScreenshot?
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

    private let maxRecentItems = 50
    private let historyKey = "screenshotHistoryEncrypted"
    private let legacyHistoryKey = "screenshotHistory"

    // Debounce save operations to avoid hammering UserDefaults
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 500_000_000 // 500ms

    private init() {
        loadHistory()
    }

    func addScreenshot(_ item: ScreenshotItem) {
        recentScreenshots.insert(item, at: 0)
        if recentScreenshots.count > maxRecentItems {
            recentScreenshots = Array(recentScreenshots.prefix(maxRecentItems))
        }
        debouncedSaveHistory()
    }

    func clearHistory() {
        recentScreenshots.removeAll()
        saveHistoryNow()
    }

    /// Schedule a debounced save (coalesces rapid changes)
    private func debouncedSaveHistory() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: saveDebounceInterval)
            guard !Task.isCancelled else { return }
            saveHistoryNow()
        }
    }

    /// Immediately persist history (called by debounce timer or clearHistory)
    func saveHistory() {
        debouncedSaveHistory()
    }

    /// Force immediate save without debouncing
    private func saveHistoryNow() {
        saveTask?.cancel()
        saveTask = nil

        // Copy array to avoid data race - background thread reads the copy
        let itemsCopy = Array(recentScreenshots)
        let key = historyKey
        let legacyKey = legacyHistoryKey
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(itemsCopy)
                let encrypted = try HistoryCrypto.encrypt(data)
                let defaults = UserDefaults.standard
                defaults.set(encrypted, forKey: key)
                defaults.removeObject(forKey: legacyKey)
            } catch {
                appStateLogger.error("Failed to encode or encrypt screenshot history: \(error.localizedDescription)")
            }
        }
    }

    private func loadHistory() {
        let defaults = UserDefaults.standard
        if let encrypted = defaults.data(forKey: historyKey) {
            do {
                let decrypted = try HistoryCrypto.decrypt(encrypted)
                if let result = decodeHistory(from: decrypted, source: "encrypted") {
                    recentScreenshots = result.items
                    if result.recovered {
                        saveHistoryNow()
                    }
                    return
                }
            } catch {
                appStateLogger.error("Failed to decrypt screenshot history: \(error.localizedDescription)")
            }
        }

        guard let data = defaults.data(forKey: legacyHistoryKey) else { return }
        if let result = decodeHistory(from: data, source: "legacy") {
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
            appStateLogger.error("Failed to decode \(source) screenshot history: \(error.localizedDescription). Attempting partial recovery.")
            // Attempt to recover individual items from the array
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
}
