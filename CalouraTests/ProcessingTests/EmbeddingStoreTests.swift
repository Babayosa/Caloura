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
}
