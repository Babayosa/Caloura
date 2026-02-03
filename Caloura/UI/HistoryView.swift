import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedItem: ScreenshotItem?
    @State private var itemToDelete: ScreenshotItem?

    private var filteredScreenshots: [ScreenshotItem] {
        if searchText.isEmpty {
            return appState.recentScreenshots
        }
        let query = searchText.lowercased()
        return appState.recentScreenshots.filter { item in
            (item.title?.lowercased().contains(query) ?? false) ||
            (item.sourceAppName?.lowercased().contains(query) ?? false) ||
            (item.sourceWindowTitle?.lowercased().contains(query) ?? false) ||
            (item.ocrText?.lowercased().contains(query) ?? false) ||
            item.fileName.lowercased().contains(query) ||
            item.tags.contains { $0.lowercased().contains(query) }
        }
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
            .cornerRadius(8)
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
                        appState.clearHistory()
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
                    appState.recentScreenshots.removeAll { $0.id == item.id }
                    appState.saveHistory()
                }
                itemToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                itemToDelete = nil
            }
        } message: {
            Text("Are you sure you want to remove this screenshot from history?")
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func openInPreview(_ item: ScreenshotItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: item.filePath))
    }

    private func openInFinder(_ item: ScreenshotItem) {
        let url = URL(fileURLWithPath: item.filePath)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    private func copyImage(_ item: ScreenshotItem) {
        let url = URL(fileURLWithPath: item.filePath)
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

// MARK: - Grid Item

struct HistoryGridItem: View {
    let item: ScreenshotItem
    let isSelected: Bool
    @ObservedObject var appState: AppState
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
            .cornerRadius(6)
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

                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // Tags
                if !item.tags.isEmpty || isSelected {
                    FlowLayout(spacing: 3) {
                        ForEach(item.tags, id: \.self) { tag in
                            TagChip(tag: tag) {
                                removeTag(tag)
                            }
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
                                    .cornerRadius(4)
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
        .cornerRadius(8)
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
            if let index = appState.recentScreenshots.firstIndex(where: { $0.id == item.id }) {
                appState.recentScreenshots[index].title = trimmed
                appState.saveHistory()
            }
        }
        isEditingTitle = false
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let index = appState.recentScreenshots.firstIndex(where: { $0.id == item.id }) {
            let normalizedNew = trimmed.lowercased()
            if !appState.recentScreenshots[index].tags.contains(where: { $0.lowercased() == normalizedNew }) {
                appState.recentScreenshots[index].tags.append(trimmed)
                appState.saveHistory()
            }
        }
        newTagText = ""
        isAddingTag = false
    }

    private func removeTag(_ tag: String) {
        if let index = appState.recentScreenshots.firstIndex(where: { $0.id == item.id }) {
            appState.recentScreenshots[index].tags.removeAll { $0 == tag }
            appState.saveHistory()
        }
    }

    private func loadThumbnailAsync() async -> NSImage? {
        let path = item.filePath
        return await Task.detached {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil as NSImage? }

            let maxDimension = 320 // 160pt × 2 for Retina
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil as NSImage?
            }
            return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
        }.value
    }
}

// MARK: - Tag Chip

struct TagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(tag)
                .font(.system(size: 10))
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.15))
        .cornerRadius(4)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - History Window Controller

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(appState: AppState) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let historyView = HistoryView(appState: appState)
        let hostingView = NSHostingView(rootView: historyView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Caloura History"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Clean up when user closes via title bar to prevent window/view leak
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                if let token = self?.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.closeObserver = nil
                }
            }
        }

        self.window = window
    }
}
