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

final class EmbeddingStore: @unchecked Sendable {
    static let currentSchemaVersion = 1

    private var entries: [EmbeddingEntry] = []
    private let storeURL: URL
    private let modelVersion: Int
    private let lock = NSLock()
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
        lock.lock()
        // Remove existing entry for same screenshot
        entries.removeAll { $0.screenshotID == screenshotID }
        entries.append(EmbeddingEntry(screenshotID: screenshotID, vector: vector, textHash: textHash))
        lock.unlock()
    }

    func remove(screenshotID: UUID) {
        lock.lock()
        entries.removeAll { $0.screenshotID == screenshotID }
        lock.unlock()
    }

    func findSimilar(to queryVector: [Double], topK: Int, threshold: Double) -> [(UUID, Double)] {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        var results: [(UUID, Double)] = []
        for entry in snapshot {
            let similarity = EmbeddingEngine.cosineSimilarity(queryVector, entry.vector)
            if similarity >= threshold {
                results.append((entry.screenshotID, similarity))
            }
        }
        results.sort { $0.1 > $1.1 }
        return Array(results.prefix(topK))
    }

    func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        do {
            let payload = EmbeddingStorePayload(
                schemaVersion: Self.currentSchemaVersion,
                modelVersion: modelVersion,
                entries: snapshot
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
            lock.lock()
            entries = decoded.entries
            lock.unlock()
        } catch {
            let message = error.localizedDescription
            embeddingStoreLogger.error("Failed to load embeddings: \(message, privacy: .public)")
            clear()
        }
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
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
        lock.lock()
        let entryCount = entries.count
        lock.unlock()
        return entryCount
    }

    func hasEmbedding(for screenshotID: UUID) -> Bool {
        lock.lock()
        let found = entries.contains { $0.screenshotID == screenshotID }
        lock.unlock()
        return found
    }
}
