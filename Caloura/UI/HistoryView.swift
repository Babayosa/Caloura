import SwiftUI
import os

/// `NSCache` is documented thread-safe, so cache reads/writes need no actor
/// hop (`@unchecked Sendable` is scoped to it). Only the hit-rate counters
/// need synchronization, handled by `metricsLock`.
private final class HistoryThumbnailStore: @unchecked Sendable {
    static let shared = HistoryThumbnailStore()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    private struct Metrics {
        var requests = 0
        var hits = 0
    }

    private let metricsLock = OSAllocatedUnfairLock(initialState: Metrics())
    private let reportInterval = 50

    func cachedImage(forKey key: String) -> NSImage? {
        let cached = cache.object(forKey: key as NSString)
        recordRequest(hit: cached != nil)
        return cached
    }

    func store(
        _ image: NSImage,
        forKey key: String,
        cost: Int
    ) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func recordRequest(hit: Bool) {
        let report: Metrics? = metricsLock.withLock { metrics in
            metrics.requests += 1
            if hit {
                metrics.hits += 1
            }
            return metrics.requests % reportInterval == 0 ? metrics : nil
        }
        guard let report else { return }
        let ratio = (Double(report.hits) / Double(max(report.requests, 1))) * 100.0
        let cacheMsg = "thumbnail_cache_summary"
            + " requests=\(report.requests)"
            + " hits=\(report.hits)"
            + " hit_rate_pct=\(ratio)"
        historyLogger.info("\(cacheMsg, privacy: .public)")
    }
}

private let historyLogger = Logger(subsystem: "com.caloura.app", category: "HistoryUI")

struct HistoryView: View {
    let appState: AppState
    @State private var searchText = ""
    @State private var selectedItem: ScreenshotItem?
    @State private var itemToDelete: ScreenshotItem?
    @State private var showClearHistoryConfirm = false
    @State private var semanticResults: Set<UUID> = []
    @State private var semanticSearchTask: Task<Void, Never>?
    @State private var copyImageTask: Task<Void, Never>?
    @State private var searchModel = HistorySearchModel()

    private var filteredScreenshots: [ScreenshotItem] {
        searchModel.filteredScreenshots(
            from: appState.recentScreenshots,
            searchText: searchText,
            semanticResults: semanticResults,
            semanticSearchEnabled: AppSettings.shared.semanticSearchEnabled
        )
    }

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search by app, title, tag, or text...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()

            if filteredScreenshots.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "No screenshots yet" : "No matching screenshots")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(filteredScreenshots) { item in
                            HistoryGridItem(
                                item: item,
                                isSelected: selectedItem == item,
                                appState: appState
                            )
                            .onTapGesture(count: 2) {
                                openInPreview(item)
                            }
                            .onTapGesture {
                                selectedItem = item
                            }
                            .contextMenu {
                                Button {
                                    openInPreview(item)
                                } label: {
                                    Label("Open", systemImage: "eye")
                                }
                                Button {
                                    copyImage(item)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button {
                                    openInFinder(item)
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    itemToDelete = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding()
                }
            }

            // Status bar
            HStack {
                Text("\(filteredScreenshots.count) screenshot\(filteredScreenshots.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !appState.recentScreenshots.isEmpty {
                    Button("Clear History") {
                        showClearHistoryConfirm = true
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .alert("Delete Screenshot", isPresented: Binding(
            get: { itemToDelete != nil },
            set: { if !$0 { itemToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let item = itemToDelete {
                    appState.deleteScreenshot(id: item.id)
                }
                itemToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                itemToDelete = nil
            }
        } message: {
            Text("Are you sure you want to remove this screenshot from history?")
        }
        .alert("Clear History", isPresented: $showClearHistoryConfirm) {
            Button("Clear", role: .destructive) {
                appState.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = appState.recentScreenshots.count
            Text(
                "Clear all history? This will permanently delete "
                + "\(count) capture\(count == 1 ? "" : "s"), their text content, "
                + "and saved files. This cannot be undone."
            )
        }
        .onChange(of: searchText) { _, newValue in
            semanticSearchTask?.cancel()
            semanticResults = []
            guard !newValue.isEmpty,
                  AppSettings.shared.semanticSearchEnabled else { return }
            let query = newValue
            let store = appState.embeddingStore
            semanticSearchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let results = await Task.detached(priority: .utility) {
                    await EmbeddingEngine.search(query: query, in: store)
                }.value
                guard !Task.isCancelled else { return }
                semanticResults = Set(results.map(\.id))
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func openInPreview(_ item: ScreenshotItem) {
        guard !item.filePath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.filePath))
    }

    private func openInFinder(_ item: ScreenshotItem) {
        guard !item.filePath.isEmpty else { return }
        let url = URL(fileURLWithPath: item.filePath)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    private func copyImage(_ item: ScreenshotItem) {
        guard !item.filePath.isEmpty else {
            appState.setStatusMessage("No image file recorded for this capture.")
            return
        }
        let url = URL(fileURLWithPath: item.filePath)
        // Cancel any in-flight copy so rapid double-taps don't race two
        // disk loads into clipboard writes in non-deterministic order.
        copyImageTask?.cancel()
        copyImageTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            guard let image = loaded else {
                appState.setStatusMessage(
                    "Image file is missing — it may have been moved or deleted from disk."
                )
                return
            }
            do {
                try ClipboardManager.copyNSImage(image)
                appState.setStatusMessage("Copied image")
            } catch {
                appState.setStatusMessage(UserFacingErrorMessage.message(for: error))
            }
        }
    }
}

// MARK: - Grid Item

struct HistoryGridItem: View {
    let item: ScreenshotItem
    let isSelected: Bool
    let appState: AppState
    @State private var thumbnail: NSImage?
    @State private var isEditingTitle = false
    @State private var editingTitle = ""
    @State private var isAddingTag = false
    @State private var newTagText = ""

    var body: some View {
        VStack(spacing: 4) {
            // Thumbnail
            Group {
                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            // Info
            VStack(alignment: .leading, spacing: 2) {
                // Title (editable when selected)
                if isSelected && isEditingTitle {
                    TextField("Title", text: $editingTitle, onCommit: {
                        commitTitleEdit()
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onExitCommand {
                        isEditingTitle = false
                    }
                } else {
                    HStack(spacing: 2) {
                        Text(item.title ?? item.sourceAppName ?? "Untitled")
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        if isSelected {
                            Button {
                                editingTitle = item.title ?? item.sourceAppName ?? "Untitled"
                                isEditingTitle = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Summary
                if let summary = item.summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // Tags (manual + auto)
                if !item.tags.isEmpty || !item.autoTags.isEmpty || isSelected {
                    FlowLayout(spacing: 3) {
                        ForEach(item.tags, id: \.self) { tag in
                            TagChip(tag: tag) {
                                removeTag(tag)
                            }
                        }

                        ForEach(item.autoTags, id: \.self) { tag in
                            AutoTagChip(tag: tag)
                        }

                        if isSelected {
                            Button {
                                isAddingTag = true
                                newTagText = ""
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $isAddingTag) {
                                HStack(spacing: 4) {
                                    TextField("Tag name", text: $newTagText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 120)
                                        .onSubmit {
                                            commitNewTag()
                                        }
                                    Button("Add") {
                                        commitNewTag()
                                    }
                                    .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                                .padding(8)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            thumbnail = await loadThumbnailAsync()
        }
        .onChange(of: isSelected) { _, selected in
            if !selected {
                isEditingTitle = false
                isAddingTag = false
            }
        }
    }

    private func commitTitleEdit() {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            appState.renameScreenshot(id: item.id, title: trimmed)
        }
        isEditingTitle = false
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appState.addTag(trimmed, to: item.id)
        newTagText = ""
        isAddingTag = false
    }

    private func removeTag(_ tag: String) {
        appState.removeTag(tag, from: item.id)
    }

    private func loadThumbnailAsync() async -> NSImage? {
        let cacheKey = "\(item.id.uuidString)|\(item.filePath)"
        if let cached = HistoryThumbnailStore.shared.cachedImage(forKey: cacheKey) {
            return cached
        }

        let path = item.filePath
        return await Task.detached(priority: .utility) {
            let generatedThumbnail = autoreleasepool { () -> (image: NSImage, cost: Int)? in
                let url = URL(fileURLWithPath: path) as CFURL
                guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }

                let maxDimension = 320 // 160pt × 2 for Retina
                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                let thumbnail = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                let cost = cgThumb.width * cgThumb.height * 4
                return (thumbnail, cost)
            }
            guard let generatedThumbnail else { return nil }
            HistoryThumbnailStore.shared.store(
                generatedThumbnail.image,
                forKey: cacheKey,
                cost: generatedThumbnail.cost
            )
            return generatedThumbnail.image
        }.value
    }
}
