import AppKit
import SwiftUI

/// A floating post-capture toolbar that appears after a screenshot is taken.
/// Shows action buttons: Copy, Markdown, Citation, Annotate, Pin, Dismiss.
/// Auto-dismisses after 6 seconds; pauses while hovered.
@MainActor
final class QuickAccessOverlay {
    static let shared = QuickAccessOverlay()

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var currentScreenshot: ProcessedScreenshot?

    private init() {}

    func show(for screenshot: ProcessedScreenshot) {
        dismiss()
        currentScreenshot = screenshot

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
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
            },
            onHoverChanged: { [weak self] hovering in
                self?.handleHover(hovering, screenshot: screenshot)
            }
        ))
        panel.contentView = hostView

        let fittingSize = hostView.fittingSize
        panel.setContentSize(fittingSize)

        // Position near bottom-right of the screen where the capture occurred,
        // falling back to the main screen. Validate the stored screen is still
        // connected to avoid crashes when an external display is unplugged.
        let storedScreen = AppState.shared.lastCaptureScreen
        let validatedScreen: NSScreen? = {
            if let stored = storedScreen, NSScreen.screens.contains(where: { $0 === stored }) {
                return stored
            }
            return nil
        }()
        let targetScreen = validatedScreen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = targetScreen {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - fittingSize.width - 20
            let y = screenFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        panel.orderFrontRegardless()

        // Auto-dismiss after 6 seconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        currentScreenshot = nil
        panel?.close()
        panel = nil
    }

    private func handleHover(_ hovering: Bool, screenshot: ProcessedScreenshot) {
        if hovering {
            dismissTimer?.invalidate()
            dismissTimer = nil
        } else {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.dismiss()
                }
            }
        }
    }

    private func handleAction(_ action: QuickAction, screenshot: ProcessedScreenshot) {
        switch action {
        case .copy:
            Task {
                await ClipboardManager.copyImage(screenshot)
            }
            AppState.shared.statusMessage = "Copied image"
        case .save:
            Task {
                let appState = AppState.shared
                // Skip if already saved to disk by the pipeline
                if let idx = appState.recentScreenshots.firstIndex(where: {
                    $0.id == screenshot.id
                }), !appState.recentScreenshots[idx].filePath.isEmpty {
                    AppState.shared.statusMessage = "Already saved to disk"
                    return
                }
                do {
                    let settings = AppSettings.shared
                    let url = try await FileOrganizer.save(
                        screenshot,
                        baseDirectory: settings.saveDirectory,
                        imageFormat: settings.imageFormat
                    )
                    // Update history item with the saved file path
                    if let idx = appState.recentScreenshots.firstIndex(where: {
                        $0.id == screenshot.id
                    }) {
                        appState.recentScreenshots[idx].filePath = url.path
                        appState.saveHistory()
                    }
                    appState.statusMessage = "Saved to disk"
                } catch {
                    appState.statusMessage = "Save failed"
                }
            }
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
        case .beautify:
            NotificationCenter.default.post(name: .beautifyLastCapture, object: nil)
        case .redact:
            NotificationCenter.default.post(name: .redactLastCapture, object: nil)
        }
        dismiss()
    }
}

// MARK: - Action Enum

enum QuickAction {
    case copy
    case save
    case markdown
    case citation
    case annotate
    case pin
    case beautify
    case redact
}

// MARK: - SwiftUI View

struct QuickAccessOverlayView: View {
    let onAction: (QuickAction) -> Void
    var onHoverChanged: ((Bool) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            overlayButton(title: "Copy", icon: "doc.on.doc", action: .copy)
            overlayButton(title: "Save", icon: "square.and.arrow.down", action: .save)
            overlayButton(title: "Markdown", icon: "doc.text", action: .markdown)
            overlayButton(title: "Citation", icon: "quote.closing", action: .citation)
            overlayButton(title: "Annotate", icon: "pencil.tip", action: .annotate)
            overlayButton(title: "Redact", icon: "eye.slash", action: .redact)
            overlayButton(title: "Pin", icon: "pin", action: .pin)
            overlayButton(title: "Beautify", icon: "sparkles", action: .beautify)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            onHoverChanged?(hovering)
        }
    }

    private func overlayButton(title: String, icon: String, action: QuickAction) -> some View {
        OverlayActionButton(title: title, icon: icon) {
            onAction(action)
        }
    }
}

/// Individual overlay button with hover highlight and accessibility label.
private struct OverlayActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 9))
            }
            .frame(width: 54, height: 36)
            .background(isHovered ? Color.primary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("\(title) screenshot")
    }
}
