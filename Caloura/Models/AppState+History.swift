import AppKit
import Foundation
import os.log

private let historyPersistenceLogger = Logger(subsystem: "com.caloura.app", category: "AppState")

struct UserDefaultsHandle: @unchecked Sendable {
    let defaults: UserDefaults
}

actor HistoryPersistenceWorker {
    private let defaultsHandle: UserDefaultsHandle
    private let historyDefaultsKey: String
    private let legacyHistoryDefaultsKey: String
    private var latestRevisionRequested: UInt64 = 0

    init(
        defaultsHandle: UserDefaultsHandle,
        historyDefaultsKey: String,
        legacyHistoryDefaultsKey: String
    ) {
        self.defaultsHandle = defaultsHandle
        self.historyDefaultsKey = historyDefaultsKey
        self.legacyHistoryDefaultsKey = legacyHistoryDefaultsKey
    }

    func persistHistory(_ encodedData: Data, to historyFileURL: URL, revision: UInt64) {
        guard revision >= latestRevisionRequested else { return }
        latestRevisionRequested = revision
        do {
            try HistoryCrypto.writeEncrypted(encodedData, to: historyFileURL)
            defaultsHandle.defaults.removeObject(forKey: historyDefaultsKey)
            defaultsHandle.defaults.removeObject(forKey: legacyHistoryDefaultsKey)
        } catch {
            let description = error.localizedDescription
            historyPersistenceLogger.error("Failed to persist screenshot history: \(description)")
        }
    }
}

struct HistoryLoadResult: Sendable {
    enum Source: Sendable { case file, defaultsEncrypted, defaultsLegacy }
    let source: Source
    let items: [ScreenshotItem]
    let recovered: Bool
}

extension AppState {
    /// Hydrate persisted state off the launch thread. Heavy I/O + AES-GCM
    /// decrypt + JSON decode run detached; main-actor state is only touched
    /// when applying the decoded result. Callers that insert screenshots
    /// during the load window are preserved via ID-dedup on apply.
    func loadPersistedState() async {
        await loadHistoryAsync()
        embeddingStore.load()
        auditStoragePermissions()
    }

    fileprivate func auditStoragePermissions() {
        let warnings = HistoryCrypto.auditStoragePermissions(historyFileURL: historyFileURL)
        if warnings.isEmpty {
            historyPersistenceLogger.debug("History storage permission audit passed.")
            return
        }
        for warning in warnings {
            historyPersistenceLogger.warning("\(warning, privacy: .public)")
        }
    }

    fileprivate func loadHistoryAsync() async {
        let fileURL = historyFileURL
        let encryptedDefaultsData = defaults.data(forKey: historyDefaultsKey)
        let legacyDefaultsData = defaults.data(forKey: legacyHistoryDefaultsKey)

        let result = await Task.detached(priority: .userInitiated) {
            Self.decodePersistedHistory(
                fileURL: fileURL,
                encryptedDefaultsData: encryptedDefaultsData,
                legacyDefaultsData: legacyDefaultsData
            )
        }.value

        guard let result else { return }

        // Merge with any items added during the async load window
        // (captures that landed before this coroutine resumed).
        let existingIds = Set(recentScreenshots.map(\.id))
        let newItems = result.items.filter { !existingIds.contains($0.id) }
        if !newItems.isEmpty {
            if recentScreenshots.isEmpty {
                recentScreenshots = newItems
            } else {
                recentScreenshots.append(contentsOf: newItems)
            }
        }

        switch result.source {
        case .file:
            defaults.removeObject(forKey: historyDefaultsKey)
            defaults.removeObject(forKey: legacyHistoryDefaultsKey)
            if result.recovered { saveHistoryNow() }
        case .defaultsEncrypted:
            defaults.removeObject(forKey: historyDefaultsKey)
            saveHistoryNow()
        case .defaultsLegacy:
            defaults.removeObject(forKey: legacyHistoryDefaultsKey)
            saveHistoryNow()
        }
    }

    nonisolated fileprivate static func decodePersistedHistory(
        fileURL: URL,
        encryptedDefaultsData: Data?,
        legacyDefaultsData: Data?
    ) -> HistoryLoadResult? {
        if let encryptedFileData = try? Data(contentsOf: fileURL) {
            do {
                let decrypted = try HistoryCrypto.decrypt(encryptedFileData)
                if let decoded = decodeHistoryData(decrypted, source: "file") {
                    return HistoryLoadResult(
                        source: .file,
                        items: decoded.items,
                        recovered: decoded.recovered
                    )
                }
            } catch {
                let description = error.localizedDescription
                historyPersistenceLogger.error(
                    "Failed to decrypt file-backed screenshot history: \(description)"
                )
            }
        }

        if let encryptedDefaultsData {
            do {
                let decrypted = try HistoryCrypto.decrypt(encryptedDefaultsData)
                if let decoded = decodeHistoryData(decrypted, source: "defaults-encrypted") {
                    return HistoryLoadResult(
                        source: .defaultsEncrypted,
                        items: decoded.items,
                        recovered: decoded.recovered
                    )
                }
            } catch {
                let description = error.localizedDescription
                historyPersistenceLogger.error(
                    "Failed to decrypt defaults-backed screenshot history: \(description)"
                )
            }
        }

        guard let legacyDefaultsData,
              let decoded = decodeHistoryData(legacyDefaultsData, source: "defaults-legacy") else {
            return nil
        }
        return HistoryLoadResult(
            source: .defaultsLegacy,
            items: decoded.items,
            recovered: decoded.recovered
        )
    }

    nonisolated fileprivate static func decodeHistoryData(
        _ data: Data,
        source: String
    ) -> (items: [ScreenshotItem], recovered: Bool)? {
        do {
            let items = try JSONDecoder().decode([ScreenshotItem].self, from: data)
            return (items, false)
        } catch {
            let description = error.localizedDescription
            let errorMessage = "Failed to decode \(source) screenshot history: \(description). "
                + "Attempting partial recovery."
            historyPersistenceLogger.error("\(errorMessage)")
            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            var recovered: [ScreenshotItem] = []
            for element in jsonArray {
                if let elementData = try? JSONSerialization.data(withJSONObject: element),
                   let item = try? JSONDecoder().decode(ScreenshotItem.self, from: elementData) {
                    recovered.append(item)
                }
            }
            let recoveredCount = recovered.count
            let totalCount = jsonArray.count
            historyPersistenceLogger.info("Recovered \(recoveredCount) of \(totalCount) history items")
            return (recovered, true)
        }
    }
}
