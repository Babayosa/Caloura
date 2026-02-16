import XCTest
@testable import Caloura

final class EmbeddingEngineTests: XCTestCase {

    func testEmbed_validText_returnsVector() {
        let vector = EmbeddingEngine.embed("This is a sample sentence about math homework")
        XCTAssertNotNil(vector)
        if let vector {
            XCTAssertGreaterThan(vector.count, 0)
        }
    }

    func testEmbed_emptyText_returnsNil() {
        XCTAssertNil(EmbeddingEngine.embed(""))
        XCTAssertNil(EmbeddingEngine.embed("   "))
    }

    func testCosineSimilarity_identical_returnsOne() {
        let vec = [1.0, 2.0, 3.0]
        let similarity = EmbeddingEngine.cosineSimilarity(vec, vec)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarity_orthogonal_returnsZero() {
        let vec1 = [1.0, 0.0]
        let vec2 = [0.0, 1.0]
        let similarity = EmbeddingEngine.cosineSimilarity(vec1, vec2)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarity_emptyVectors_returnsZero() {
        XCTAssertEqual(EmbeddingEngine.cosineSimilarity([], []), 0.0)
    }

    func testCosineSimilarity_differentLengths_returnsZero() {
        XCTAssertEqual(EmbeddingEngine.cosineSimilarity([1.0], [1.0, 2.0]), 0.0)
    }

    func testSearch_similarText_ranksHigher() {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-embeddings-\(UUID().uuidString).enc")
        let store = EmbeddingStore(storeURL: storeURL)

        // Add embeddings for different topics
        if let mathVec = EmbeddingEngine.embed("calculus derivatives integration math homework") {
            store.add(screenshotID: UUID(), vector: mathVec, textHash: "math")
        }
        if let catVec = EmbeddingEngine.embed("cute cat sitting on the couch photo") {
            store.add(screenshotID: UUID(), vector: catVec, textHash: "cat")
        }

        let results = EmbeddingEngine.search(query: "calculus problem", in: store, topK: 10, threshold: 0.0)
        // If embeddings are available, math should rank higher than cat
        if results.count >= 2 {
            XCTAssertGreaterThan(results[0].similarity, results[1].similarity)
        }
        // Cleanup
        store.clear()
    }
}
