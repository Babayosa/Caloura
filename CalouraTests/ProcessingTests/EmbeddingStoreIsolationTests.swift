import XCTest
@testable import Caloura

/// Test-only seam: these helpers execute in the same isolation domain as
/// `save()`/`load()` themselves, so observing `Thread.isMainThread` here
/// observes the thread the store's I/O executes on.
private extension EmbeddingStore {
    func saveAndReportMainThread() -> Bool {
        save()
        return Thread.isMainThread
    }

    func loadAndReportMainThread() -> Bool {
        load()
        return Thread.isMainThread
    }
}

/// Audit item 3.1: `EmbeddingStore` file I/O (JSON encode + AES-GCM +
/// atomic write) must not execute on the main thread when invoked from
/// main-actor call sites (AppState delete/prune/loadPersistedState).
final class EmbeddingStoreIsolationTests: XCTestCase {
    private func makeTempStoreURL() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("isolation-\(UUID().uuidString).enc")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    @MainActor
    func testSaveAndLoad_executeOffTheMainThread_whenInvokedFromMainActor() async {
        let url = makeTempStoreURL()
        let store = EmbeddingStore(storeURL: url)
        await store.add(screenshotID: UUID(), vector: [1.0, 2.0, 3.0], textHash: "hash")

        let savedOnMain = await store.saveAndReportMainThread()
        XCTAssertFalse(
            savedOnMain,
            "save() I/O must not execute on the main thread when invoked from a main-actor context"
        )

        let loadedOnMain = await store.loadAndReportMainThread()
        XCTAssertFalse(
            loadedOnMain,
            "load() I/O must not execute on the main thread when invoked from a main-actor context"
        )
    }
}
