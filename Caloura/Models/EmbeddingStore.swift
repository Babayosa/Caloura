import Foundation
import os.log

private let embeddingStoreLogger = Logger(
    subsystem: "com.caloura.app",
    category: "EmbeddingStore"
)

struct EmbeddingEntry: Codable {
    let screenshotID: UUID
    let vector: [Double]
    let textHash: String
}

private struct EmbeddingStorePayload: Codable {
    let schemaVersion: Int
    let modelVersion: Int
    let entries: [EmbeddingEntry]
}

/// Actor so file I/O (JSON encode + AES-GCM + atomic write in `save()`,
/// read + decrypt + decode in `load()`) never executes on the main actor's
/// thread — main-actor call sites pay only an actor hop (audit item 3.1).
/// Actor serialization also orders saves: every mutation executed before a
/// `save()` is reflected in that save's snapshot, so the last write to the
/// file always contains all prior mutations.
actor EmbeddingStore {
    static let currentSchemaVersion = 1

    private var entries: [EmbeddingEntry] = []
    private let storeURL: URL
    private let modelVersion: Int
    private static let encryptionPurpose = "embedding-storage"

    init(
        storeURL: URL? = nil,
        modelVersion: Int = EmbeddingEngine.modelVersion
    ) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.modelVersion = modelVersion
    }

    private static func defaultStoreURL() -> URL {
        HistoryCrypto.applicationSupportURL(filename: "embeddings.enc")
    }

    func add(screenshotID: UUID, vector: [Double], textHash: String) {
        // Remove existing entry for same screenshot
        entries.removeAll { $0.screenshotID == screenshotID }
        entries.append(EmbeddingEntry(screenshotID: screenshotID, vector: vector, textHash: textHash))
    }

    func remove(screenshotID: UUID) {
        entries.removeAll { $0.screenshotID == screenshotID }
    }

    func remove(screenshotIDs: [UUID]) {
        guard !screenshotIDs.isEmpty else { return }
        let removalSet = Set(screenshotIDs)
        entries.removeAll { removalSet.contains($0.screenshotID) }
    }

    func findSimilar(to queryVector: [Double], topK: Int, threshold: Double) -> [(UUID, Double)] {
        guard topK > 0 else { return [] }

        var results: [(UUID, Double)] = []
        results.reserveCapacity(min(topK, entries.count))
        for entry in entries {
            let similarity = EmbeddingEngine.cosineSimilarity(queryVector, entry.vector)
            guard similarity >= threshold else { continue }

            if results.count == topK, let lastSimilarity = results.last?.1, similarity <= lastSimilarity {
                continue
            }
            let insertionIndex = results.firstIndex { similarity > $0.1 } ?? results.endIndex
            results.insert((entry.screenshotID, similarity), at: insertionIndex)
            if results.count > topK {
                results.removeLast()
            }
        }
        return results
    }

    func save() {
        do {
            let payload = EmbeddingStorePayload(
                schemaVersion: Self.currentSchemaVersion,
                modelVersion: modelVersion,
                entries: entries
            )
            let data = try JSONEncoder().encode(payload)
            try HistoryCrypto.writeEncrypted(data, to: storeURL, purpose: Self.encryptionPurpose)
        } catch {
            let message = error.localizedDescription
            embeddingStoreLogger.error("Failed to persist embeddings: \(message, privacy: .public)")
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let decrypted = try HistoryCrypto.decrypt(data, purpose: Self.encryptionPurpose)
            let decoded = try JSONDecoder().decode(EmbeddingStorePayload.self, from: decrypted)
            guard decoded.schemaVersion == Self.currentSchemaVersion,
                  decoded.modelVersion == modelVersion else {
                let mismatchMessage =
                    "Discarding incompatible embedding store "
                    + "(schema=\(decoded.schemaVersion), model=\(decoded.modelVersion), "
                    + "expectedSchema=\(Self.currentSchemaVersion), expectedModel=\(self.modelVersion))"
                embeddingStoreLogger.info(
                    "\(mismatchMessage, privacy: .public)"
                )
                clear()
                return
            }
            entries = decoded.entries
        } catch {
            let message = error.localizedDescription
            embeddingStoreLogger.debug(
                "Discarding unreadable embedding store: \(message, privacy: .public)"
            )
            clear()
        }
    }

    func clear() {
        entries = []
        do {
            try FileManager.default.removeItem(at: storeURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            let message = error.localizedDescription
            embeddingStoreLogger.error("Failed to remove embedding store: \(message, privacy: .public)")
        }
    }

    var count: Int {
        entries.count
    }

    func hasEmbedding(for screenshotID: UUID) -> Bool {
        entries.contains { $0.screenshotID == screenshotID }
    }
}
