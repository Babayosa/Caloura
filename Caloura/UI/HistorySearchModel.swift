import Foundation

final class HistorySearchModel {

    private struct CacheKey: Equatable {
        let items: [ScreenshotItem]
        let searchText: String
        let semanticResults: Set<UUID>
        let semanticSearchEnabled: Bool
    }

    private var cachedKey: CacheKey?
    private var cachedResult: [ScreenshotItem] = []

    /// Number of full filter scans performed by this instance.
    /// Test seam for asserting one scan per render-equivalent access pattern.
    private(set) var scanCount = 0

    /// Memoizing wrapper around the static filter: re-scans only when an
    /// input changed, so repeated accesses within one SwiftUI body pass
    /// (and across renders with unchanged inputs) cost one scan total.
    func filteredScreenshots(
        from items: [ScreenshotItem],
        searchText: String,
        semanticResults: Set<UUID>,
        semanticSearchEnabled: Bool
    ) -> [ScreenshotItem] {
        let key = CacheKey(
            items: items,
            searchText: searchText,
            semanticResults: semanticResults,
            semanticSearchEnabled: semanticSearchEnabled
        )
        if key == cachedKey {
            return cachedResult
        }
        scanCount += 1
        cachedResult = Self.filteredScreenshots(
            from: items,
            searchText: searchText,
            semanticResults: semanticResults,
            semanticSearchEnabled: semanticSearchEnabled
        )
        cachedKey = key
        return cachedResult
    }

    /// Filter screenshots by text query with optional semantic result fallback.
    /// Returns all items when `searchText` is empty.
    static func filteredScreenshots(
        from items: [ScreenshotItem],
        searchText: String,
        semanticResults: Set<UUID>,
        semanticSearchEnabled: Bool
    ) -> [ScreenshotItem] {
        if searchText.isEmpty {
            return items
        }
        let query = searchText.lowercased()

        let substringMatches = items.filter { item in
            matchesSubstring(item, query: query)
        }
        if !substringMatches.isEmpty { return substringMatches }

        guard semanticSearchEnabled, !semanticResults.isEmpty else { return [] }
        return items.filter { semanticResults.contains($0.id) }
    }

    /// Check whether a single item matches the lowercased query across all text fields.
    static func matchesSubstring(_ item: ScreenshotItem, query: String) -> Bool {
        (item.title?.lowercased().contains(query) ?? false)
            || (item.sourceAppName?.lowercased().contains(query) ?? false)
            || (item.sourceWindowTitle?.lowercased().contains(query) ?? false)
            || (item.ocrText?.lowercased().contains(query) ?? false)
            || (item.summary?.lowercased().contains(query) ?? false)
            || item.fileName.lowercased().contains(query)
            || item.tags.contains { $0.lowercased().contains(query) }
            || item.autoTags.contains { $0.lowercased().contains(query) }
    }
}
