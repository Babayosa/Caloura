import AppKit
import SwiftUI

/// Manages floating pinned screenshot windows.
/// Each pinned screenshot is an always-on-top, resizable NSPanel.
@MainActor
final class PinnedScreenshotManager {
    static let shared = PinnedScreenshotManager()

    private var pinnedWindows: [NSPanel] = []
    private var observers: [NSPanel: NSObjectProtocol] = [:]
    private var panelsByKey: [String: NSPanel] = [:]

    private init() {}

    private func dedupKey(for screenshot: ProcessedScreenshot) -> String {
        screenshot.filePath?.absoluteString ?? "\(ObjectIdentifier(screenshot))"
    }

    /// Pin a screenshot as a floating always-on-top window.
    func pin(_ screenshot: ProcessedScreenshot) {
        let key = dedupKey(for: screenshot)
        if let existing = panelsByKey[key], pinnedWindows.contains(where: { $0 === existing }) {
            existing.orderFrontRegardless()
            return
        }

        let image = screenshot.image
        let imageSize = image.size

        // Scale down if image is larger than half the screen
        let maxSize: CGFloat = 600
        let scale = min(1.0, maxSize / max(imageSize.width, imageSize.height))
        let windowSize = NSSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        let title = "Pinned — \(screenshot.fileName.isEmpty ? "Screenshot" : screenshot.fileName)"
        let panel = configurePanel(size: windowSize, title: title)

        let pinnedView = PinnedScreenshotView(
            image: image,
            onCopy: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
            },
            onClose: { [weak panel] in
                panel?.close()
            }
        )
        let hostView = NSHostingView(rootView: pinnedView)
        panel.contentView = hostView
        panel.center()

        pinnedWindows.append(panel)
        panelsByKey[key] = panel
        registerCloseObserver(for: panel)
        panel.orderFrontRegardless()
    }

    private func configurePanel(size: NSSize, title: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.title = title
        panel.minSize = NSSize(width: 100, height: 100)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func registerCloseObserver(for panel: NSPanel) {
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let panel = notification.object as? NSPanel else { return }
            weak var closedPanel = panel
            Task { @MainActor in
                guard let self = self, let closedPanel else { return }
                self.pinnedWindows.removeAll { $0 === closedPanel }
                self.panelsByKey = self.panelsByKey.filter { $0.value !== closedPanel }
                if let token = self.observers.removeValue(forKey: closedPanel) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
        observers[panel] = observer
    }

}

// MARK: - SwiftUI View

struct PinnedScreenshotView: View {
    let image: NSImage
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Button {
                    onCopy?()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    onClose?()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial)

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
