import Foundation

struct HistorySearchModel {

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
