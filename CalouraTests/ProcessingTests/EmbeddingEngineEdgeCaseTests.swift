import XCTest
@testable import Caloura

final class EmbeddingEngineEdgeCaseTests: XCTestCase {

    func testEmbed_veryLongText() {
        let longText = String(repeating: "This is a test sentence. ", count: 400)
        // Should not crash or OOM
        _ = EmbeddingEngine.embed(longText)
    }

    func testSearch_emptyStore_returnsEmpty() {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString).enc")
        let store = EmbeddingStore(storeURL: storeURL)
        let results = EmbeddingEngine.search(query: "hello", in: store)
        XCTAssertTrue(results.isEmpty)
        store.clear()
    }

    func testEmbed_nonEnglishText_gracefulFallback() {
        // Non-English text may not have embeddings, should return nil gracefully
        let result = EmbeddingEngine.embed("これはテストです")
        // Either nil or valid vector — no crash
        if let result {
            XCTAssertGreaterThan(result.count, 0)
        }
    }

    func testCosineSimilarity_zeroVector() {
        let zero = [0.0, 0.0, 0.0]
        let nonZero = [1.0, 2.0, 3.0]
        XCTAssertEqual(EmbeddingEngine.cosineSimilarity(zero, nonZero), 0.0)
    }
}
