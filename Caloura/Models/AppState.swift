import AppKit
import Observation
import os.log
import SwiftUI

private let appStateLogger = Logger(subsystem: "com.caloura.app", category: "AppState")

struct RecentStatusMessage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
    let timestamp: Date
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var recentScreenshots: [ScreenshotItem] = []
    var lastScreenshot: ProcessedScreenshot? {
        didSet { resetLastScreenshotTimer() }
    }
    var isCapturing: Bool = false
    var hasScreenRecordingPermission: Bool = false
    var statusMessage: String = "" {
        didSet {
            let trimmed = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != oldValue else { return }
            recentStatusMessages.insert(
                RecentStatusMessage(message: trimmed, timestamp: Date()),
                at: 0
            )
            if recentStatusMessages.count > Self.maxRecentStatusMessages {
                recentStatusMessages = Array(
                    recentStatusMessages.prefix(Self.maxRecentStatusMessages)
                )
            }
        }
    }

    /// In-memory rolling log of the last `maxRecentStatusMessages`
    /// `statusMessage` values. Exposed for the menu bar "Recent activity"
    /// drawer so users can see transient errors after they disappear.
    private(set) var recentStatusMessages: [RecentStatusMessage] = []
    private static let maxRecentStatusMessages = 10
    var isCountingDown: Bool = false
    var countdownRemaining: Int = 0
    private(set) var lastCapturePreviewPhase: CapturePreviewPhase = .rawPreviewReady
    private(set) var lastCapturePreviewScreenshotID: UUID?

    /// Stores the last area capture rect for the repeat capture feature.
    var lastCaptureRect: CGRect?
    /// Stores the screen used for the last area capture. Not SwiftUI-observed —
    /// NSScreen isn't Equatable and no view reads this directly.
    @ObservationIgnored var lastCaptureScreen: NSScreen?

    var lastPIIResult: PIIDetectionResult?

    let embeddingStore = EmbeddingStore()

    private let maxRecentItems = 50
    let historyDefaultsKey = "screenshotHistoryEncrypted"
    let legacyHistoryDefaultsKey = "screenshotHistory"
    let defaults: UserDefaults
    let historyFileURL: URL
    private let historyPersistence: HistoryPersistenceWorker
    private var previewPhasesByScreenshotID: [UUID: CapturePreviewPhase] = [:]
    private var piiResultsByScreenshotID: [UUID: PIIDetectionResult] = [:]

    // Debounce save operations to avoid hammering disk writes.
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 500_000_000 // 500ms
    private var lastScreenshotTimer: Timer?
    private var historyRevision: UInt64 = 0

    init(defaults: UserDefaults = .standard, historyStoreURL: URL? = nil) {
        self.defaults = defaults
        self.historyFileURL = historyStoreURL ?? Self.defaultHistoryFileURL()
        self.historyPersistence = HistoryPersistenceWorker(
            defaultsHandle: UserDefaultsHandle(defaults: defaults),
            historyDefaultsKey: "screenshotHistoryEncrypted",
            legacyHistoryDefaultsKey: "screenshotHistory"
        )
    }

    func addScreenshot(_ item: ScreenshotItem) {
        recentScreenshots.insert(item, at: 0)
        pruneRecentScreenshotsIfNeeded()
        debouncedSaveHistory()
    }

    func syncProcessedScreenshot(_ screenshot: ProcessedScreenshot) {
        let item = screenshot.toScreenshotItem()
        if let existingIndex = recentScreenshots.firstIndex(where: { $0.id == item.id }) {
            let existing = recentScreenshots[existingIndex]
            recentScreenshots[existingIndex] = existing.updated(
                filePath: item.filePath,
                fileName: item.fileName,
                presetName: screenshot.presetName,
                width: item.width,
                height: item.height,
                title: item.title
            )
        } else {
            recentScreenshots.insert(item, at: 0)
            pruneRecentScreenshotsIfNeeded()
        }
        debouncedSaveHistory()
    }

    func updateScreenshot(id: UUID, _ update: (inout ScreenshotItem) -> Void) {
        guard let index = recentScreenshots.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&recentScreenshots[index])
        debouncedSaveHistory()
    }

    func deleteScreenshot(id: UUID) {
        guard let index = recentScreenshots.firstIndex(where: { $0.id == id }) else {
            return
        }

        recentScreenshots.remove(at: index)
        removeAssociatedState(for: id)
        embeddingStore.remove(screenshotID: id)
        embeddingStore.save()
        debouncedSaveHistory()
    }

    func renameScreenshot(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateScreenshot(id: id) { item in
            item.title = trimmed
        }
    }

    func addTag(_ tag: String, to id: UUID) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let normalizedTag = trimmed.lowercased()
        updateScreenshot(id: id) { item in
            guard !item.tags.contains(where: { $0.lowercased() == normalizedTag }) else {
                return
            }
            item.tags.append(trimmed)
        }
    }

    func removeTag(_ tag: String, from id: UUID) {
        updateScreenshot(id: id) { item in
            item.tags.removeAll { $0 == tag }
        }
    }

    func applyMetadata(_ metadata: ScreenshotMetadata, to id: UUID) {
        updateScreenshot(id: id) { item in
            item.smartFileName = metadata.smartFileName
            item.summary = metadata.summary
            item.autoTags = metadata.tags
        }
    }

    func markEmbeddingVersion(_ version: Int, for id: UUID) {
        updateScreenshot(id: id) { item in
            item.embeddingVersion = version
        }
    }

    func setStatusMessage(_ message: String) {
        statusMessage = message
    }

    func clearHistory() {
        recentScreenshots.removeAll()
        previewPhasesByScreenshotID.removeAll()
        piiResultsByScreenshotID.removeAll()
        lastCapturePreviewPhase = .rawPreviewReady
        lastCapturePreviewScreenshotID = nil
        lastPIIResult = nil
        embeddingStore.clear()
        saveHistoryNow()
    }

    func setCapturePreviewPhase(
        _ phase: CapturePreviewPhase,
        for screenshotID: UUID
    ) {
        previewPhasesByScreenshotID[screenshotID] = phase
        lastCapturePreviewScreenshotID = screenshotID
        lastCapturePreviewPhase = phase
    }

    func previewPhase(for screenshotID: UUID) -> CapturePreviewPhase {
        previewPhasesByScreenshotID[screenshotID] ?? .rawPreviewReady
    }

    func setPIIResult(_ result: PIIDetectionResult) {
        piiResultsByScreenshotID[result.screenshotID] = result
        lastPIIResult = result
    }

    func piiResult(for screenshotID: UUID) -> PIIDetectionResult? {
        piiResultsByScreenshotID[screenshotID]
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

    /// Force immediate save without debouncing.
    func saveHistoryNow() {
        saveTask?.cancel()
        saveTask = nil

        // Copy array to avoid data races on detached thread.
        let itemsCopy = Array(recentScreenshots)
        historyRevision &+= 1
        let revision = historyRevision
        let encodedData: Data
        do {
            encodedData = try JSONEncoder().encode(itemsCopy)
        } catch {
            appStateLogger.error("Failed to encode screenshot history: \(error.localizedDescription)")
            return
        }

        let historyFileURL = self.historyFileURL
        let historyPersistence = self.historyPersistence

        Task(priority: .utility) {
            await historyPersistence.persistHistory(
                encodedData,
                to: historyFileURL,
                revision: revision
            )
        }
    }

    /// Synchronous save for termination path. Blocks the calling thread.
    func saveHistorySync() {
        saveTask?.cancel()
        saveTask = nil
        let itemsCopy = Array(recentScreenshots)
        let url = historyFileURL
        do {
            let data = try JSONEncoder().encode(itemsCopy)
            try HistoryCrypto.writeEncrypted(data, to: url)
        } catch {
            appStateLogger.error("Failed to flush history on termination: \(error.localizedDescription)")
        }
    }

    private static func defaultHistoryFileURL() -> URL {
        HistoryCrypto.applicationSupportURL(filename: "history.enc")
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

    private func pruneRecentScreenshotsIfNeeded() {
        guard recentScreenshots.count > maxRecentItems else { return }
        let removed = recentScreenshots.suffix(recentScreenshots.count - maxRecentItems)
        recentScreenshots.removeLast(recentScreenshots.count - maxRecentItems)
        guard !removed.isEmpty else { return }

        for item in removed {
            removeAssociatedState(for: item.id)
            embeddingStore.remove(screenshotID: item.id)
        }
        if let lastCapturePreviewScreenshotID,
           previewPhasesByScreenshotID[lastCapturePreviewScreenshotID] == nil {
            self.lastCapturePreviewScreenshotID = nil
            self.lastCapturePreviewPhase = .rawPreviewReady
        }
        if let lastPIIResult,
           piiResultsByScreenshotID[lastPIIResult.screenshotID] == nil {
            self.lastPIIResult = nil
        }
        embeddingStore.save()
    }

    private func removeAssociatedState(for screenshotID: UUID) {
        previewPhasesByScreenshotID[screenshotID] = nil
        piiResultsByScreenshotID[screenshotID] = nil
        if lastCapturePreviewScreenshotID == screenshotID {
            lastCapturePreviewScreenshotID = nil
            lastCapturePreviewPhase = .rawPreviewReady
        }
        if lastPIIResult?.screenshotID == screenshotID {
            lastPIIResult = nil
        }
    }
}
