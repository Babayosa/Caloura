import AppKit
import SwiftUI

/// Manages floating pinned screenshot windows.
/// Each pinned screenshot is an always-on-top, resizable NSPanel.
@MainActor
final class PinnedScreenshotManager {
    static let shared = PinnedScreenshotManager()

    private var pinnedWindows: [NSPanel] = []

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

        let hostView = NSHostingView(rootView: PinnedScreenshotView(image: image))
        panel.contentView = hostView

        // Center on screen
        panel.center()
        panel.orderFrontRegardless()

        // Track for cleanup
        pinnedWindows.append(panel)

        // Remove from tracking when closed
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let closedPanel = notification.object as? NSPanel else { return }
            Task { @MainActor in
                self?.pinnedWindows.removeAll { $0 === closedPanel }
            }
        }
    }

    /// Close all pinned windows.
    func unpinAll() {
        for panel in pinnedWindows {
            panel.close()
        }
        pinnedWindows.removeAll()
    }
}

// MARK: - SwiftUI View

struct PinnedScreenshotView: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
