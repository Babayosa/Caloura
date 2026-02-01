import AppKit
import SwiftUI

/// Manages floating pinned screenshot windows.
/// Each pinned screenshot is an always-on-top, resizable NSPanel.
@MainActor
final class PinnedScreenshotManager {
    static let shared = PinnedScreenshotManager()

    private var pinnedWindows: [NSPanel] = []
    private var observers: [NSPanel: NSObjectProtocol] = [:]

    private init() {}

    /// Pin a screenshot as a floating always-on-top window.
    func pin(_ screenshot: ProcessedScreenshot) {
        let image = screenshot.image
        let imageSize = image.size

        // Scale down if image is larger than half the screen
        let maxSize: CGFloat = 600
        let scale = min(1.0, maxSize / max(imageSize.width, imageSize.height))
        let windowSize = NSSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
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
        panel.title = "Pinned — \(screenshot.fileName.isEmpty ? "Screenshot" : screenshot.fileName)"
        panel.minSize = NSSize(width: 100, height: 100)
        panel.isReleasedWhenClosed = false

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

        // Center on screen
        panel.center()

        // Track for cleanup
        pinnedWindows.append(panel)

        // Remove from tracking when closed, and clean up the observer itself
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let closedPanel = notification.object as? NSPanel else { return }
            Task { @MainActor in
                guard let self = self else { return }
                self.pinnedWindows.removeAll { $0 === closedPanel }
                if let token = self.observers.removeValue(forKey: closedPanel) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
        observers[panel] = observer

        panel.orderFrontRegardless()
    }

    /// Close all pinned windows.
    func unpinAll() {
        let windowsToClose = pinnedWindows
        let observersToRemove = observers

        // Clear tracking state first so willCloseNotification callbacks are no-ops
        pinnedWindows.removeAll()
        observers.removeAll()

        // Close panels before removing observers so willCloseNotification fires
        // while observers are still valid (avoiding stale-state callbacks)
        for panel in windowsToClose {
            panel.close()
        }

        // Now remove observers after panels are closed
        for (_, token) in observersToRemove {
            NotificationCenter.default.removeObserver(token)
        }
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
