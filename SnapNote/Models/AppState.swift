import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var recentScreenshots: [ScreenshotItem] = []
    @Published var lastScreenshot: ProcessedScreenshot?
    @Published var isCapturing: Bool = false
    @Published var captureMode: CaptureMode = .area
    @Published var hasScreenRecordingPermission: Bool = false
    @Published var statusMessage: String = ""

    /// Stores the last area capture rect for the repeat capture feature.
    var lastCaptureRect: CGRect?
    /// Stores the screen used for the last area capture.
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

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(recentScreenshots) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let items = try? JSONDecoder().decode([ScreenshotItem].self, from: data) else {
            return
        }
        recentScreenshots = items
    }
}
