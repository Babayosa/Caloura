import XCTest
@testable import Caloura

/// Phase 3.0 baseline for audit finding 3.3: `HistoryView.filteredScreenshots`
/// is a computed property (`HistoryView.swift:62-69`) re-evaluated on every
/// access during a body pass — `:98` (`isEmpty`), `:111` (`ForEach`), and `:154`
/// (twice, in the count label) — i.e. up to 4 full filter scans per render,
/// each lowercasing every text field of every item
/// (`HistorySearchModel.matchesSubstring`).
///
/// This test measures one filter scan over synthetic 50- and 500-item
/// histories. Multiply by ~4 for the per-render cost on main.
final class PerfBaselineHistoryFilterTests: XCTestCase {

    private static func makeItems(count: Int) -> [ScreenshotItem] {
        let ocrWords = [
            "revenue", "dashboard", "meeting", "deploy", "screenshot",
            "kubernetes", "summary", "quarterly", "report", "approval"
        ]
        return (0..<count).map { index in
            let ocrText = (0..<250)
                .map { ocrWords[($0 + index) % ocrWords.count] }
                .joined(separator: " ")
            return ScreenshotItem(
                filePath: "/tmp/perf-baseline/shot-\(index).png",
                fileName: "shot-\(index).png",
                sourceAppName: "Safari",
                sourceWindowTitle: "Window \(index) — Project Notes",
                captureMode: "area",
                ocrText: ocrText + (index % 10 == 0 ? " invoice" : ""),
                width: 1920,
                height: 1080,
                title: "Capture \(index)",
                tags: ["work", "tag\(index % 7)"],
                summary: "Synthetic summary for capture \(index)",
                autoTags: ["auto\(index % 5)", "screen"]
            )
        }
    }

    private func measureFilter(
        itemCount: Int,
        searchText: String,
        label: String,
        expectedMatches: Int? = nil
    ) {
        let items = Self.makeItems(count: itemCount)
        let result = HistorySearchModel.filteredScreenshots(
            from: items,
            searchText: searchText,
            semanticResults: [],
            semanticSearchEnabled: false
        )
        if let expectedMatches {
            XCTAssertEqual(result.count, expectedMatches, "Synthetic data must behave deterministically")
        }

        let stats = PerfBaselineMeasurement.measure(warmup: 5, iterations: 50) {
            _ = HistorySearchModel.filteredScreenshots(
                from: items,
                searchText: searchText,
                semanticResults: [],
                semanticSearchEnabled: false
            )
        }
        print(PerfBaselineMeasurement.summary(
            "HistoryFilter \(label) items=\(itemCount) ocrChars~2000/item"
                + " (x4 per HistoryView body pass)",
            stats
        ))
        XCTAssertLessThan(stats.meanMS, 1_000, "Sanity bound only — not a perf gate")
    }

    func testBaseline_filter50Items_missQuery_worstCaseFullScan() {
        // A query that matches nothing forces a scan of every field of every
        // item (lowercasing each) — the worst case the audit describes.
        measureFilter(itemCount: 50, searchText: "zzqxv", label: "miss-query", expectedMatches: 0)
    }

    func testBaseline_filter50Items_hitQuery() {
        measureFilter(itemCount: 50, searchText: "invoice", label: "hit-query", expectedMatches: 5)
    }

    func testBaseline_filter500Items_missQuery_worstCaseFullScan() {
        measureFilter(itemCount: 500, searchText: "zzqxv", label: "miss-query", expectedMatches: 0)
    }

    func testBaseline_filter500Items_hitQuery() {
        measureFilter(itemCount: 500, searchText: "invoice", label: "hit-query", expectedMatches: 50)
    }

    func testBaseline_filter500Items_emptyQuery_passthrough() {
        // Empty search returns the array unchanged — confirms the cheap path.
        measureFilter(itemCount: 500, searchText: "", label: "empty-query", expectedMatches: 500)
    }
}
