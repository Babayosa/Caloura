import Foundation
import XCTest
@testable import Caloura

/// Audit item 3.3: `HistoryView` accesses `filteredScreenshots` up to 4× per
/// body pass (`isEmpty`, `ForEach`, twice in the count label). These tests pin
/// the fix: with unchanged inputs, a render-equivalent burst of accesses must
/// perform exactly ONE full filter scan, and any input change must invalidate
/// the cache without changing filter semantics.
final class HistorySearchModelCacheTests: XCTestCase {

    private func makeItem(
        id: UUID = UUID(),
        fileName: String = "test.png",
        ocrText: String? = nil,
        tags: [String] = []
    ) -> ScreenshotItem {
        ScreenshotItem(
            id: id,
            filePath: "/tmp/\(fileName)",
            fileName: fileName,
            sourceAppName: "Safari",
            sourceWindowTitle: "Window",
            captureMode: "area",
            ocrText: ocrText,
            title: nil,
            tags: tags,
            summary: nil,
            autoTags: []
        )
    }

    private func makeItems(count: Int) -> [ScreenshotItem] {
        (0..<count).map { index in
            makeItem(
                fileName: "shot-\(index).png",
                ocrText: "quarterly report \(index)" + (index % 10 == 0 ? " invoice" : ""),
                tags: ["work"]
            )
        }
    }

    // MARK: - One scan per render-equivalent access pattern

    func testFourAccessesWithUnchangedInputs_performExactlyOneScan() {
        let model = HistorySearchModel()
        let items = makeItems(count: 50)

        // Render-equivalent pattern: 4 accesses per body pass with the same inputs.
        var results: [[ScreenshotItem]] = []
        for _ in 0..<4 {
            results.append(model.filteredScreenshots(
                from: items,
                searchText: "invoice",
                semanticResults: [],
                semanticSearchEnabled: false
            ))
        }

        XCTAssertEqual(model.scanCount, 1, "Unchanged inputs must cost exactly one filter scan")
        for result in results {
            XCTAssertEqual(result, results[0], "Every access must return the same filtered list")
        }
        XCTAssertEqual(results[0].count, 5)
    }

    func testRepeatedAccessesAcrossRenders_stayAtOneScanUntilInputsChange() {
        let model = HistorySearchModel()
        let items = makeItems(count: 50)

        for _ in 0..<8 {
            _ = model.filteredScreenshots(
                from: items,
                searchText: "",
                semanticResults: [],
                semanticSearchEnabled: false
            )
        }
        XCTAssertEqual(model.scanCount, 1)

        // A query change is a new input — exactly one more scan for the next burst.
        for _ in 0..<4 {
            _ = model.filteredScreenshots(
                from: items,
                searchText: "invoice",
                semanticResults: [],
                semanticSearchEnabled: false
            )
        }
        XCTAssertEqual(model.scanCount, 2)
    }

    // MARK: - Cache invalidation on every input

    func testEachInputChange_invalidatesCache() {
        let model = HistorySearchModel()
        let items = makeItems(count: 10)

        _ = model.filteredScreenshots(
            from: items, searchText: "invoice",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(model.scanCount, 1)

        // Items changed (e.g. new capture appended).
        let grown = items + [makeItem(fileName: "new.png", ocrText: "invoice")]
        let afterGrow = model.filteredScreenshots(
            from: grown, searchText: "invoice",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(model.scanCount, 2)
        XCTAssertEqual(afterGrow.count, 2)

        // Semantic results changed.
        _ = model.filteredScreenshots(
            from: grown, searchText: "invoice",
            semanticResults: [grown[0].id], semanticSearchEnabled: false
        )
        XCTAssertEqual(model.scanCount, 3)

        // Semantic toggle changed.
        _ = model.filteredScreenshots(
            from: grown, searchText: "invoice",
            semanticResults: [grown[0].id], semanticSearchEnabled: true
        )
        XCTAssertEqual(model.scanCount, 4)
    }

    // MARK: - Cached path is semantically identical to the pure filter

    func testCachedResult_matchesStaticFilter_includingSemanticFallback() {
        let model = HistorySearchModel()
        let items = makeItems(count: 20)
        let semanticIDs: Set<UUID> = [items[3].id, items[7].id]

        // "zzqxv" matches no substring; semantic fallback should kick in.
        let expected = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "zzqxv",
            semanticResults: semanticIDs, semanticSearchEnabled: true
        )
        XCTAssertEqual(expected.count, 2, "Semantic fallback must apply in this fixture")

        var cached: [ScreenshotItem] = []
        for _ in 0..<4 {
            cached = model.filteredScreenshots(
                from: items, searchText: "zzqxv",
                semanticResults: semanticIDs, semanticSearchEnabled: true
            )
        }
        XCTAssertEqual(cached, expected)
        XCTAssertEqual(model.scanCount, 1)
    }
}
