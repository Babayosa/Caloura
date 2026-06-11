import XCTest
@testable import Caloura

/// Phase 3.0 baseline for audit finding 3.1: `EmbeddingStore.save()/load()`
/// (JSON encode + AES-GCM encrypt + atomic disk write) runs synchronously on
/// the main actor (`AppState.swift:128`, `:296` via `pruneRecentScreenshotsIfNeeded`,
/// `AppState+History.swift:55`).
///
/// This test quantifies the cost of one `save()` and one `load()` with a
/// 50-item history on the calling (main) thread. It records numbers; it does
/// not gate. Sanity bounds are deliberately generous.
final class PerfBaselineEmbeddingStoreTests: XCTestCase {

    private static let historyItemCount = 50
    private static let vectorDimensions = 512

    private func makePopulatedStore(storeURL: URL) -> EmbeddingStore {
        let store = EmbeddingStore(storeURL: storeURL)
        for index in 0..<Self.historyItemCount {
            let vector = (0..<Self.vectorDimensions).map { dimension in
                sin(Double(index * Self.vectorDimensions + dimension))
            }
            store.add(
                screenshotID: UUID(),
                vector: vector,
                textHash: String(format: "%064x", index)
            )
        }
        return store
    }

    private func makeTempStoreURL() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perf-baseline-\(UUID().uuidString).enc")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Measures `save()` exactly as production calls it: synchronously on the
    /// main actor with a full (50-item) history.
    @MainActor
    func testBaseline_save50ItemHistory_onMainThread() throws {
        XCTAssertTrue(Thread.isMainThread, "Baseline must run on the calling (main) thread")
        let storeURL = makeTempStoreURL()
        let store = makePopulatedStore(storeURL: storeURL)

        let stats = PerfBaselineMeasurement.measure(warmup: 2, iterations: 20) {
            store.save()
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: storeURL.path)
        let fileSize = (attributes?[.size] as? Int) ?? 0
        print(PerfBaselineMeasurement.summary(
            "EmbeddingStore.save items=\(Self.historyItemCount) dims=\(Self.vectorDimensions)"
                + " fileBytes=\(fileSize) thread=main",
            stats
        ))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "save() must have produced the encrypted store file"
        )
        XCTAssertLessThan(stats.meanMS, 5_000, "Sanity bound only — not a perf gate")
    }

    /// Measures `load()` (read + AES-GCM decrypt + JSON decode) as production
    /// calls it from `loadPersistedState()` on the main actor.
    @MainActor
    func testBaseline_load50ItemHistory_onMainThread() throws {
        XCTAssertTrue(Thread.isMainThread, "Baseline must run on the calling (main) thread")
        let storeURL = makeTempStoreURL()
        makePopulatedStore(storeURL: storeURL).save()

        let freshStore = EmbeddingStore(storeURL: storeURL)
        let stats = PerfBaselineMeasurement.measure(warmup: 2, iterations: 20) {
            freshStore.load()
        }

        print(PerfBaselineMeasurement.summary(
            "EmbeddingStore.load items=\(Self.historyItemCount) dims=\(Self.vectorDimensions) thread=main",
            stats
        ))

        XCTAssertEqual(
            freshStore.count,
            Self.historyItemCount,
            "load() must round-trip all entries"
        )
        XCTAssertLessThan(stats.meanMS, 5_000, "Sanity bound only — not a perf gate")
    }
}
