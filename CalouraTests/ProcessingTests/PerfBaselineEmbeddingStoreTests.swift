import XCTest
@testable import Caloura

/// Phase 3 measurement for audit finding 3.1. Baseline (pre-fix, class on
/// the calling/main thread): save median 3.413 ms, load median 5.454 ms.
/// `EmbeddingStore` is now an actor, so `save()`/`load()` execute on the
/// actor's executor off the main thread; main-actor call sites pay only the
/// cost of spawning a fire-and-forget `Task` (measured separately below).
///
/// These tests record numbers; they do not gate. Sanity bounds are
/// deliberately generous.
final class PerfBaselineEmbeddingStoreTests: XCTestCase {

    private static let historyItemCount = 50
    private static let vectorDimensions = 512

    @MainActor
    private func makePopulatedStore(storeURL: URL) async -> EmbeddingStore {
        let store = EmbeddingStore(storeURL: storeURL)
        for index in 0..<Self.historyItemCount {
            let vector = (0..<Self.vectorDimensions).map { dimension in
                sin(Double(index * Self.vectorDimensions + dimension))
            }
            await store.add(
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

    /// Measures the awaited round-trip of `save()` from a main-actor caller
    /// (actor hop + JSON encode + AES-GCM + atomic write on the actor's
    /// executor), plus the main-actor cost of the production fire-and-forget
    /// pattern (`Task { await store.save() }`) — the only part the main
    /// thread now pays.
    @MainActor
    func testBaseline_save50ItemHistory_fromMainActor() async throws {
        XCTAssertTrue(Thread.isMainThread, "Baseline must run on the calling (main) thread")
        let storeURL = makeTempStoreURL()
        let store = await makePopulatedStore(storeURL: storeURL)

        let stats = await PerfBaselineMeasurement.measureAsync(warmup: 2, iterations: 20) {
            await store.save()
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: storeURL.path)
        let fileSize = (attributes?[.size] as? Int) ?? 0
        print(PerfBaselineMeasurement.summary(
            "EmbeddingStore.save items=\(Self.historyItemCount) dims=\(Self.vectorDimensions)"
                + " fileBytes=\(fileSize) thread=actor-off-main awaited-round-trip",
            stats
        ))

        let enqueueStats = PerfBaselineMeasurement.measure(warmup: 2, iterations: 20) {
            Task {
                await store.save()
            }
        }
        print(PerfBaselineMeasurement.summary(
            "EmbeddingStore.save main-actor enqueue (fire-and-forget Task spawn)",
            enqueueStats
        ))
        // Quiesce: the actor serializes jobs, so awaiting one more save
        // guarantees all fire-and-forget saves above have completed.
        await store.save()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "save() must have produced the encrypted store file"
        )
        XCTAssertLessThan(stats.meanMS, 5_000, "Sanity bound only — not a perf gate")
    }

    /// Measures the awaited round-trip of `load()` (read + AES-GCM decrypt +
    /// JSON decode on the actor's executor) as production calls it from
    /// `loadPersistedState()` on the main actor.
    @MainActor
    func testBaseline_load50ItemHistory_fromMainActor() async throws {
        XCTAssertTrue(Thread.isMainThread, "Baseline must run on the calling (main) thread")
        let storeURL = makeTempStoreURL()
        await makePopulatedStore(storeURL: storeURL).save()

        let freshStore = EmbeddingStore(storeURL: storeURL)
        let stats = await PerfBaselineMeasurement.measureAsync(warmup: 2, iterations: 20) {
            await freshStore.load()
        }

        print(PerfBaselineMeasurement.summary(
            "EmbeddingStore.load items=\(Self.historyItemCount) dims=\(Self.vectorDimensions)"
                + " thread=actor-off-main awaited-round-trip",
            stats
        ))

        let count = await freshStore.count
        XCTAssertEqual(
            count,
            Self.historyItemCount,
            "load() must round-trip all entries"
        )
        XCTAssertLessThan(stats.meanMS, 5_000, "Sanity bound only — not a perf gate")
    }
}
