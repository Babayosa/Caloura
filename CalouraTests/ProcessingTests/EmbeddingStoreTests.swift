import XCTest
@testable import Caloura

final class EmbeddingStoreTests: XCTestCase {
    private func makeTestStore() -> EmbeddingStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-store-\(UUID().uuidString).enc")
        return EmbeddingStore(storeURL: url)
    }

    func testAddAndRetrieve_roundTrip() {
        let store = makeTestStore()
        let id = UUID()
        let vector = [1.0, 2.0, 3.0]
        store.add(screenshotID: id, vector: vector, textHash: "abc")
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(store.hasEmbedding(for: id))
        store.clear()
    }

    func testRemove_deletesEntry() {
        let store = makeTestStore()
        let id = UUID()
        store.add(screenshotID: id, vector: [1.0], textHash: "a")
        XCTAssertEqual(store.count, 1)
        store.remove(screenshotID: id)
        XCTAssertEqual(store.count, 0)
        store.clear()
    }

    func testClear_emptiesStore() {
        let store = makeTestStore()
        store.add(screenshotID: UUID(), vector: [1.0], textHash: "a")
        store.add(screenshotID: UUID(), vector: [2.0], textHash: "b")
        XCTAssertEqual(store.count, 2)
        store.clear()
        XCTAssertEqual(store.count, 0)
    }

    func testSaveAndLoad_encrypted() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-persist-\(UUID().uuidString).enc")
        let store1 = EmbeddingStore(storeURL: url)
        let id = UUID()
        store1.add(screenshotID: id, vector: [1.0, 2.0, 3.0], textHash: "test")
        store1.save()

        let store2 = EmbeddingStore(storeURL: url)
        store2.load()
        XCTAssertEqual(store2.count, 1)
        XCTAssertTrue(store2.hasEmbedding(for: id))

        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    func testFindSimilar_threshold() {
        let store = makeTestStore()
        store.add(screenshotID: UUID(), vector: [1.0, 0.0, 0.0], textHash: "a")
        store.add(screenshotID: UUID(), vector: [0.0, 1.0, 0.0], textHash: "b")

        let results = store.findSimilar(to: [1.0, 0.0, 0.0], topK: 10, threshold: 0.9)
        XCTAssertEqual(results.count, 1, "Only exact/near match should pass high threshold")
        store.clear()
    }

    func testFindSimilar_limitsTopKWithoutLosingOrder() {
        let store = makeTestStore()
        let top = UUID()
        let second = UUID()
        let third = UUID()
        store.add(screenshotID: top, vector: [1.0, 0.0, 0.0], textHash: "top")
        store.add(screenshotID: second, vector: [0.8, 0.2, 0.0], textHash: "second")
        store.add(screenshotID: third, vector: [0.7, 0.3, 0.0], textHash: "third")

        let results = store.findSimilar(to: [1.0, 0.0, 0.0], topK: 2, threshold: 0.0)

        XCTAssertEqual(results.map(\.0), [top, second])
        XCTAssertGreaterThanOrEqual(results[0].1, results[1].1)
        store.clear()
    }

    func testLoad_modelVersionMismatch_clearsStore() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-version-mismatch-\(UUID().uuidString).enc")
        let writer = EmbeddingStore(storeURL: url, modelVersion: 1)
        let screenshotID = UUID()
        writer.add(screenshotID: screenshotID, vector: [1.0, 2.0], textHash: "hash")
        writer.save()

        let reader = EmbeddingStore(storeURL: url, modelVersion: 2)
        reader.load()

        XCTAssertEqual(reader.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoad_unreadableStore_clearsCorruptedFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-corrupt-\(UUID().uuidString).enc")
        try Data("not encrypted".utf8).write(to: url, options: .atomic)

        let store = EmbeddingStore(storeURL: url)
        store.load()

        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
