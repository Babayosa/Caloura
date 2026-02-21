import Foundation
import XCTest
@testable import Caloura

final class HistorySearchModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(
        id: UUID = UUID(),
        fileName: String = "test.png",
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        ocrText: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        autoTags: [String] = []
    ) -> ScreenshotItem {
        ScreenshotItem(
            id: id,
            filePath: "/tmp/\(fileName)",
            fileName: fileName,
            sourceAppName: sourceAppName,
            sourceWindowTitle: sourceWindowTitle,
            captureMode: "area",
            ocrText: ocrText,
            title: title,
            tags: tags,
            summary: summary,
            autoTags: autoTags
        )
    }

    // MARK: - Empty query returns all

    func testEmptyQuery_returnsAllItems() {
        let items = [
            makeItem(fileName: "a.png"),
            makeItem(fileName: "b.png"),
            makeItem(fileName: "c.png")
        ]

        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "",
            semanticResults: [], semanticSearchEnabled: false
        )

        XCTAssertEqual(result.count, 3)
    }

    // MARK: - Matches across all 7 text fields

    func testMatchesFileName() {
        let items = [makeItem(fileName: "ProjectDesign.png")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "design",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testMatchesSourceAppName() {
        let items = [makeItem(sourceAppName: "Safari")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "safari",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testMatchesSourceWindowTitle() {
        let items = [makeItem(sourceWindowTitle: "GitHub Pull Request")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "pull request",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testMatchesOCRText() {
        let items = [makeItem(ocrText: "Error 404 not found")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "404",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testMatchesTitle() {
        let items = [makeItem(title: "Login Screen")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "login",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testMatchesSummary() {
        let items = [makeItem(summary: "Dashboard with analytics charts")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "analytics",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testMatchesTags() {
        let items = [makeItem(tags: ["bug", "critical"])]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "critical",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testMatchesAutoTags() {
        let items = [makeItem(autoTags: ["code", "xcode"])]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "xcode",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Case insensitivity

    func testCaseInsensitive() {
        let items = [makeItem(sourceAppName: "Xcode")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "XCODE",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - No match returns empty

    func testNoMatch_returnsEmpty() {
        let items = [makeItem(fileName: "test.png", sourceAppName: "Safari")]
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "nonexistent",
            semanticResults: [], semanticSearchEnabled: false
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Semantic result merging

    func testSemanticFallback_usedWhenNoSubstringMatch() {
        let id1 = UUID()
        let id2 = UUID()
        let items = [
            makeItem(id: id1, fileName: "alpha.png"),
            makeItem(id: id2, fileName: "beta.png")
        ]

        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "something unrelated",
            semanticResults: [id1], semanticSearchEnabled: true
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, id1)
    }

    func testSemanticFallback_ignoredWhenDisabled() {
        let id1 = UUID()
        let items = [makeItem(id: id1, fileName: "alpha.png")]

        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "something unrelated",
            semanticResults: [id1], semanticSearchEnabled: false
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testSubstringMatchTakesPrecedenceOverSemantic() {
        let id1 = UUID()
        let id2 = UUID()
        let items = [
            makeItem(id: id1, fileName: "alpha.png", sourceAppName: "Safari"),
            makeItem(id: id2, fileName: "beta.png")
        ]

        // "safari" matches id1 by substring, id2 is in semantic results
        let result = HistorySearchModel.filteredScreenshots(
            from: items, searchText: "safari",
            semanticResults: [id2], semanticSearchEnabled: true
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, id1)
    }
}
