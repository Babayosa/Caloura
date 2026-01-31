import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedItem: ScreenshotItem?

    private var filteredScreenshots: [ScreenshotItem] {
        if searchText.isEmpty {
            return appState.recentScreenshots
        }
        let query = searchText.lowercased()
        return appState.recentScreenshots.filter { item in
            (item.sourceAppName?.lowercased().contains(query) ?? false) ||
            (item.sourceWindowTitle?.lowercased().contains(query) ?? false) ||
            (item.ocrText?.lowercased().contains(query) ?? false) ||
            item.fileName.lowercased().contains(query)
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
                TextField("Search by app, title, or text...", text: $searchText)
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
                            HistoryGridItem(item: item, isSelected: selectedItem == item)
                                .onTapGesture {
                                    selectedItem = item
                                }
                                .onTapGesture(count: 2) {
                                    openInFinder(item)
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
        .frame(minWidth: 400, minHeight: 300)
    }

    private func openInFinder(_ item: ScreenshotItem) {
        let url = URL(fileURLWithPath: item.filePath)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - Grid Item

struct HistoryGridItem: View {
    let item: ScreenshotItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            // Thumbnail
            Group {
                if let image = loadThumbnail() {
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
                Text(item.sourceAppName ?? "Unknown")
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }

    private func loadThumbnail() -> NSImage? {
        let url = URL(fileURLWithPath: item.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }
}

// MARK: - History Window Controller

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?

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
        window.contentView = hostingView
        window.title = "SnapNote History"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
