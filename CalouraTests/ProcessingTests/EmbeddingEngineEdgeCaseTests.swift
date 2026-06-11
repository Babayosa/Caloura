import XCTest
@testable import Caloura

final class EmbeddingEngineEdgeCaseTests: XCTestCase {

    func testEmbed_veryLongText() async {
        let longText = String(repeating: "This is a test sentence. ", count: 400)
        _ = await EmbeddingEngine.embed(longText)
    }

    func testSearch_emptyStore_returnsEmpty() async {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString).enc")
        let store = EmbeddingStore(storeURL: storeURL)
        let results = await EmbeddingEngine.search(query: "hello", in: store)
        XCTAssertTrue(results.isEmpty)
        await store.clear()
    }

    func testEmbed_nonEnglishText_gracefulFallback() async {
        let result = await EmbeddingEngine.embed("これはテストです")
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
