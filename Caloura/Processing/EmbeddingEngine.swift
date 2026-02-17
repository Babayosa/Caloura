import Foundation
import NaturalLanguage

struct EmbeddingEngine {
    /// Generate sentence embedding for text. Returns nil if embedding unavailable.
    static func embed(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try sentence embedding first
        if let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english) {
            if let vector = sentenceEmbedding.vector(for: trimmed) {
                return vector
            }
        }

        // Fallback: average word embeddings
        if let wordEmbedding = NLEmbedding.wordEmbedding(for: .english) {
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            var vectors: [[Double]] = []
            for word in words {
                if let vec = wordEmbedding.vector(for: word.lowercased()) {
                    vectors.append(vec)
                }
            }
            guard !vectors.isEmpty else { return nil }
            let dim = vectors[0].count
            var avg = [Double](repeating: 0, count: dim)
            for vec in vectors {
                for i in 0..<dim {
                    avg[i] += vec[i]
                }
            }
            let count = Double(vectors.count)
            return avg.map { $0 / count }
        }

        return nil
    }

    /// Cosine similarity between two vectors. Returns 0 if vectors are incompatible.
    static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<lhs.count {
            dot += lhs[i] * rhs[i]
            normA += lhs[i] * lhs[i]
            normB += rhs[i] * rhs[i]
        }
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    /// Search for similar items in the embedding store.
    static func search(
        query: String,
        in store: EmbeddingStore,
        topK: Int = 10,
        threshold: Double = 0.3
    ) -> [(id: UUID, similarity: Double)] {
        guard let queryVector = embed(query) else { return [] }
        return store.findSimilar(to: queryVector, topK: topK, threshold: threshold)
    }
}
