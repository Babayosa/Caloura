import Foundation

struct EmbeddingEntry: Codable {
    let screenshotID: UUID
    let vector: [Double]
    let textHash: String
}

final class EmbeddingStore: @unchecked Sendable {
    private var entries: [EmbeddingEntry] = []
    private let storeURL: URL
    private let lock = NSLock()
    private static let encryptionPurpose = "embedding-storage"

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
    }

    private static func defaultStoreURL() -> URL {
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Caloura/embeddings.enc")
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return fallback
        }
        return appSupport
            .appendingPathComponent("Caloura")
            .appendingPathComponent("embeddings.enc")
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
            let data = try JSONEncoder().encode(snapshot)
            let encrypted = try HistoryCrypto.encrypt(data, purpose: Self.encryptionPurpose)

            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encrypted.write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        } catch {
            // Non-fatal — embeddings will be regenerated on next launch
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let decrypted = try HistoryCrypto.decrypt(data, purpose: Self.encryptionPurpose)
            let decoded = try JSONDecoder().decode([EmbeddingEntry].self, from: decrypted)
            lock.lock()
            entries = decoded
            lock.unlock()
        } catch {
            // Corrupt or incompatible — start fresh
        }
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: storeURL)
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
