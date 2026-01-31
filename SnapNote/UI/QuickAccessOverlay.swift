import AppKit
import SwiftUI

/// A floating post-capture toolbar that appears after a screenshot is taken.
/// Shows action buttons: Copy, Markdown, Citation, Annotate, Pin, Dismiss.
/// Auto-dismisses after 5 seconds.
@MainActor
final class QuickAccessOverlay {
    static let shared = QuickAccessOverlay()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    private init() {}

    func show(for screenshot: ProcessedScreenshot) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 48),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false

        let hostView = NSHostingView(rootView: QuickAccessOverlayView(
            onAction: { [weak self] action in
                self?.handleAction(action, screenshot: screenshot)
            }
        ))
        panel.contentView = hostView

        // Position near bottom-right of the main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 340
            let y = screenFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        // Auto-dismiss after 5 seconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.close()
        panel = nil
    }

    private func handleAction(_ action: QuickAction, screenshot: ProcessedScreenshot) {
        switch action {
        case .copy:
            ClipboardManager.copyImage(screenshot)
            AppState.shared.statusMessage = "Copied image"
        case .markdown:
            ClipboardManager.copyAsMarkdown(screenshot)
            AppState.shared.statusMessage = "Copied as Markdown"
        case .citation:
            ClipboardManager.copyWithCitation(screenshot)
            AppState.shared.statusMessage = "Copied with citation"
        case .annotate:
            NotificationCenter.default.post(name: .annotateLastCapture, object: nil)
        case .pin:
            NotificationCenter.default.post(name: .pinScreenshot, object: nil)
        }
        dismiss()
    }
}

// MARK: - Action Enum

enum QuickAction {
    case copy
    case markdown
    case citation
    case annotate
    case pin
}

// MARK: - SwiftUI View

struct QuickAccessOverlayView: View {
    let onAction: (QuickAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            overlayButton(title: "Copy", icon: "doc.on.doc", action: .copy)
            overlayButton(title: "Markdown", icon: "doc.text", action: .markdown)
            overlayButton(title: "Citation", icon: "quote.closing", action: .citation)
            overlayButton(title: "Annotate", icon: "pencil.tip", action: .annotate)
            overlayButton(title: "Pin", icon: "pin", action: .pin)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func overlayButton(title: String, icon: String, action: QuickAction) -> some View {
        Button {
            onAction(action)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 9))
            }
            .frame(width: 54, height: 36)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
