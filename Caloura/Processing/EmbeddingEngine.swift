import Foundation
import NaturalLanguage

struct EmbeddingEngine {
    static let modelVersion = 1
    private static let resources = EmbeddingResources()

    /// Generate sentence embedding for text. Returns nil if embedding unavailable.
    /// Loads underlying `NLEmbedding` lazily on first call via a background Task —
    /// keeps the model off the launch thread.
    static func embed(_ text: String) async -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let vector = await resources.sentenceVector(for: trimmed) {
            return vector
        }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var vectors: [[Double]] = []
        for word in words {
            if let vector = await resources.wordVector(for: word.lowercased()) {
                vectors.append(vector)
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

    private final class EmbeddingBox: @unchecked Sendable {
        let embedding: NLEmbedding?
        init(_ embedding: NLEmbedding?) { self.embedding = embedding }
    }

    private actor EmbeddingResources {
        private var sentenceTask: Task<EmbeddingBox, Never>?
        private var wordTask: Task<EmbeddingBox, Never>?

        func sentenceVector(for text: String) async -> [Double]? {
            let box = await sentenceEmbedding()
            return box.embedding?.vector(for: text)
        }

        func wordVector(for word: String) async -> [Double]? {
            let box = await wordEmbedding()
            return box.embedding?.vector(for: word)
        }

        private func sentenceEmbedding() async -> EmbeddingBox {
            if let existing = sentenceTask {
                return await existing.value
            }
            let task = Task.detached(priority: .utility) {
                EmbeddingBox(NLEmbedding.sentenceEmbedding(for: .english))
            }
            sentenceTask = task
            return await task.value
        }

        private func wordEmbedding() async -> EmbeddingBox {
            if let existing = wordTask {
                return await existing.value
            }
            let task = Task.detached(priority: .utility) {
                EmbeddingBox(NLEmbedding.wordEmbedding(for: .english))
            }
            wordTask = task
            return await task.value
        }
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
    ) async -> [(id: UUID, similarity: Double)] {
        guard let queryVector = await embed(query) else { return [] }
        return await store.findSimilar(to: queryVector, topK: topK, threshold: threshold)
    }
}
