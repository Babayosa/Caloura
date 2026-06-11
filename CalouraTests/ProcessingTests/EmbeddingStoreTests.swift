import XCTest
@testable import Caloura

final class EmbeddingStoreTests: XCTestCase {
    private func makeTestStore() -> EmbeddingStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-store-\(UUID().uuidString).enc")
        return EmbeddingStore(storeURL: url)
    }

    func testAddAndRetrieve_roundTrip() async {
        let store = makeTestStore()
        let id = UUID()
        let vector = [1.0, 2.0, 3.0]
        await store.add(screenshotID: id, vector: vector, textHash: "abc")
        let count = await store.count
        XCTAssertEqual(count, 1)
        let hasEmbedding = await store.hasEmbedding(for: id)
        XCTAssertTrue(hasEmbedding)
        await store.clear()
    }

    func testRemove_deletesEntry() async {
        let store = makeTestStore()
        let id = UUID()
        await store.add(screenshotID: id, vector: [1.0], textHash: "a")
        let countAfterAdd = await store.count
        XCTAssertEqual(countAfterAdd, 1)
        await store.remove(screenshotID: id)
        let countAfterRemove = await store.count
        XCTAssertEqual(countAfterRemove, 0)
        await store.clear()
    }

    func testRemoveBatch_deletesOnlyListedEntries() async {
        let store = makeTestStore()
        let first = UUID()
        let second = UUID()
        let kept = UUID()
        await store.add(screenshotID: first, vector: [1.0], textHash: "a")
        await store.add(screenshotID: second, vector: [2.0], textHash: "b")
        await store.add(screenshotID: kept, vector: [3.0], textHash: "c")

        await store.remove(screenshotIDs: [first, second])

        let count = await store.count
        XCTAssertEqual(count, 1)
        let hasKept = await store.hasEmbedding(for: kept)
        XCTAssertTrue(hasKept)
        await store.clear()
    }

    func testClear_emptiesStore() async {
        let store = makeTestStore()
        await store.add(screenshotID: UUID(), vector: [1.0], textHash: "a")
        await store.add(screenshotID: UUID(), vector: [2.0], textHash: "b")
        let countAfterAdds = await store.count
        XCTAssertEqual(countAfterAdds, 2)
        await store.clear()
        let countAfterClear = await store.count
        XCTAssertEqual(countAfterClear, 0)
    }

    func testSaveAndLoad_encrypted() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-persist-\(UUID().uuidString).enc")
        let store1 = EmbeddingStore(storeURL: url)
        let id = UUID()
        await store1.add(screenshotID: id, vector: [1.0, 2.0, 3.0], textHash: "test")
        await store1.save()

        let store2 = EmbeddingStore(storeURL: url)
        await store2.load()
        let count = await store2.count
        XCTAssertEqual(count, 1)
        let hasEmbedding = await store2.hasEmbedding(for: id)
        XCTAssertTrue(hasEmbedding)

        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    /// Audit item 3.1 ordering guarantee: concurrent mutate+save pairs must
    /// never leave the on-disk store missing a mutation. Each task's save
    /// runs after its own add (program order), and the actor serializes all
    /// jobs, so the globally last save snapshots every add.
    func testConcurrentAddAndSave_finalFileContainsAllEntries() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-ordering-\(UUID().uuidString).enc")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        let store = EmbeddingStore(storeURL: url)
        let ids = (0..<20).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    await store.add(
                        screenshotID: id,
                        vector: [Double(index)],
                        textHash: "hash-\(index)"
                    )
                    await store.save()
                }
            }
        }

        let reader = EmbeddingStore(storeURL: url)
        await reader.load()
        let count = await reader.count
        XCTAssertEqual(count, ids.count, "Final file must contain every concurrently added entry")
        for id in ids {
            let hasEmbedding = await reader.hasEmbedding(for: id)
            XCTAssertTrue(hasEmbedding, "Entry \(id) missing from final persisted store")
        }
    }

    func testFindSimilar_threshold() async {
        let store = makeTestStore()
        await store.add(screenshotID: UUID(), vector: [1.0, 0.0, 0.0], textHash: "a")
        await store.add(screenshotID: UUID(), vector: [0.0, 1.0, 0.0], textHash: "b")

        let results = await store.findSimilar(to: [1.0, 0.0, 0.0], topK: 10, threshold: 0.9)
        XCTAssertEqual(results.count, 1, "Only exact/near match should pass high threshold")
        await store.clear()
    }

    func testFindSimilar_limitsTopKWithoutLosingOrder() async {
        let store = makeTestStore()
        let top = UUID()
        let second = UUID()
        let third = UUID()
        await store.add(screenshotID: top, vector: [1.0, 0.0, 0.0], textHash: "top")
        await store.add(screenshotID: second, vector: [0.8, 0.2, 0.0], textHash: "second")
        await store.add(screenshotID: third, vector: [0.7, 0.3, 0.0], textHash: "third")

        let results = await store.findSimilar(to: [1.0, 0.0, 0.0], topK: 2, threshold: 0.0)

        XCTAssertEqual(results.map(\.0), [top, second])
        XCTAssertGreaterThanOrEqual(results[0].1, results[1].1)
        await store.clear()
    }

    func testLoad_modelVersionMismatch_clearsStore() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-version-mismatch-\(UUID().uuidString).enc")
        let writer = EmbeddingStore(storeURL: url, modelVersion: 1)
        let screenshotID = UUID()
        await writer.add(screenshotID: screenshotID, vector: [1.0, 2.0], textHash: "hash")
        await writer.save()

        let reader = EmbeddingStore(storeURL: url, modelVersion: 2)
        await reader.load()

        let count = await reader.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoad_unreadableStore_clearsCorruptedFile() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-corrupt-\(UUID().uuidString).enc")
        try Data("not encrypted".utf8).write(to: url, options: .atomic)

        let store = EmbeddingStore(storeURL: url)
        await store.load()

        let count = await store.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // Regression guard: anything an attacker could read off disk (UUID,
    // text hash, vector floats) must not survive in plaintext. If a future
    // edit to save() ever writes JSON directly, this test fires.
    func testSave_writesEncryptedBytesNotPlaintextJSON() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-encrypted-bytes-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = EmbeddingStore(storeURL: url)
        let screenshotID = UUID()
        let textHash = "UNIQUE-PLAINTEXT-MARKER-9F3A2B"
        await store.add(screenshotID: screenshotID, vector: [1.0, 2.0, 3.0], textHash: textHash)
        await store.save()

        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 0, "encrypted file should not be empty")

        // Plaintext markers MUST NOT appear in the on-disk bytes.
        let asString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(
            asString.contains(textHash),
            "textHash leaked in plaintext on disk — encryption not applied"
        )
        XCTAssertFalse(
            asString.contains(screenshotID.uuidString),
            "screenshotID leaked in plaintext on disk"
        )
        XCTAssertFalse(
            asString.contains("schemaVersion"),
            "JSON envelope leaked in plaintext on disk"
        )
        XCTAssertFalse(
            asString.contains("entries"),
            "JSON entries leaked in plaintext on disk"
        )

        // Bytewise check covers the case where the textHash bytes appear
        // in some non-UTF8 encoding within the ciphertext — the marker is
        // unique enough that any byte-window match indicates leakage.
        let marker = Data(textHash.utf8)
        XCTAssertFalse(
            bytes.range(of: marker) != nil,
            "textHash byte sequence leaked in ciphertext envelope"
        )
    }
}
