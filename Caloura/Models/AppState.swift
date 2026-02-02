import AppKit
import Foundation
import os.log
import SwiftUI

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
    private let historyKey = "screenshotHistory"

    private init() {
        loadHistory()
    }

    func addScreenshot(_ item: ScreenshotItem) {
        recentScreenshots.insert(item, at: 0)
        if recentScreenshots.count > maxRecentItems {
            recentScreenshots = Array(recentScreenshots.prefix(maxRecentItems))
        }
        saveHistory()
    }

    func clearHistory() {
        recentScreenshots.removeAll()
        saveHistory()
    }

    func saveHistory() {
        do {
            let data = try JSONEncoder().encode(recentScreenshots)
            UserDefaults.standard.set(data, forKey: historyKey)
        } catch {
            Self.logger.error("Failed to encode screenshot history: \(error.localizedDescription)")
        }
    }

    private static let logger = Logger(subsystem: "com.caloura.app", category: "AppState")

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return }
        do {
            recentScreenshots = try JSONDecoder().decode([ScreenshotItem].self, from: data)
        } catch {
            Self.logger.error("Failed to decode screenshot history: \(error.localizedDescription). Attempting partial recovery.")
            // Attempt to recover individual items from the array
            if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var recovered: [ScreenshotItem] = []
                for element in jsonArray {
                    if let elementData = try? JSONSerialization.data(withJSONObject: element),
                       let item = try? JSONDecoder().decode(ScreenshotItem.self, from: elementData) {
                        recovered.append(item)
                    }
                }
                Self.logger.info("Recovered \(recovered.count) of \(jsonArray.count) history items")
                recentScreenshots = recovered
                saveHistory()
            }
        }
    }
}
