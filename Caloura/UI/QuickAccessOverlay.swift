import AppKit
import os.log
import SwiftUI

/// A floating post-capture preview chip that appears after a screenshot is taken.
/// The chip keeps the primary actions compact and pushes expert actions into an overflow menu.
@MainActor
final class QuickAccessOverlay {
    static let shared = QuickAccessOverlay()

    private let logger = Logger(subsystem: "com.caloura.app", category: "QuickAccessOverlay")

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var currentScreenshot: ProcessedScreenshot?
    /// True while a share sheet is anchored to the panel. Suppresses the
    /// hover/auto-dismiss timers so the panel (the picker's anchor view) is not
    /// torn out from under the open share menu. Always cleared by `dismiss()`.
    private var isPresentingShare = false
    /// The picker + its delegate must be retained for the lifetime of the menu;
    /// `NSSharingServicePicker` holds its delegate weakly and is otherwise ownerless.
    private var sharePicker: NSSharingServicePicker?
    private var sharePickerDelegate: SharePickerDelegate?
    /// Bumped by every `dismiss()` (and each new share) so a superseded share's
    /// completion callback is recognized as stale and cannot tear down a newer chip.
    private var shareGeneration = 0

    private init() {}

    var debugPanel: NSPanel? {
        panel
    }

    func show(for screenshot: ProcessedScreenshot) {
        dismiss()
        currentScreenshot = screenshot

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let hostView = NSHostingView(rootView: QuickAccessOverlayView(
            screenshot: screenshot,
            appState: AppState.shared,
            onAction: { [weak self] action in
                self?.handleAction(action, screenshot: screenshot)
            },
            onHoverChanged: { [weak self] hovering in
                self?.handleHover(hovering)
            }
        ))
        panel.contentView = hostView

        let fittingSize = hostView.fittingSize
        panel.setContentSize(fittingSize)

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

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        // Reset all share state so a lingering flag can't disable the auto-dismiss
        // timer on the next chip, and bump the generation so any in-flight picker
        // callback from a superseded share is treated as stale (see presentSharePicker).
        isPresentingShare = false
        sharePicker = nil
        sharePickerDelegate = nil
        shareGeneration += 1
        currentScreenshot = nil
        panel?.close()
        panel = nil
    }

    private func handleHover(_ hovering: Bool) {
        // While the share sheet is up, the pointer moves onto the picker menu
        // (a hover-exit on the chip); do not let that re-arm the dismiss timer.
        // Log so a stuck flag (share never resolved) is observable in Console;
        // `dismiss()` — called on the next capture — is the recovery path.
        guard !isPresentingShare else {
            logger.debug("handleHover suppressed while share sheet is presenting")
            return
        }
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

    private func handleAction(
        _ action: CaptureQuickAction,
        screenshot: ProcessedScreenshot
    ) {
        if action == .dismiss {
            dismiss()
            return
        }
        if action == .share {
            presentSharePicker(for: screenshot)
            return
        }
        CapturePipeline.shared.distributionService.performQuickAction(action, for: screenshot)
        dismiss()
    }

    /// Presents the native macOS share sheet anchored to the overlay panel.
    /// Keeps the panel alive (the picker anchors to its content view) until the
    /// user picks a service or cancels, then dismisses the chip.
    private func presentSharePicker(for screenshot: ProcessedScreenshot) {
        guard let contentView = panel?.contentView else { return }
        let items = CaptureShareItems.items(for: screenshot)
        guard !items.isEmpty else {
            dismiss()
            return
        }

        isPresentingShare = true
        dismissTimer?.invalidate()
        dismissTimer = nil

        shareGeneration += 1
        let generation = shareGeneration
        let picker = NSSharingServicePicker(items: items)
        let delegate = SharePickerDelegate { [weak self] in
            // Ignore a completion from a share that a newer capture/dismiss
            // already superseded — it must not tear down the current chip.
            guard let self, self.shareGeneration == generation else { return }
            self.dismiss()
        }
        sharePicker = picker
        sharePickerDelegate = delegate
        picker.delegate = delegate
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .maxY)
    }
}

/// Retained delegate that fires once the share picker resolves (service chosen
/// or cancelled) so the overlay can tear down cleanly afterward. AppKit delivers
/// this callback on the main thread, so the conformance uses `assumeIsolated`.
@MainActor
private final class SharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        MainActor.assumeIsolated { onFinish() }
    }
}

struct QuickAccessPresentationModel {
    let primaryActions: [CaptureQuickAction]
    let overflowActions: [CaptureQuickAction]
    let showsPendingBadge: Bool
    let showsPIIBadge: Bool

    init(
        screenshot: ProcessedScreenshot,
        previewPhase: CapturePreviewPhase,
        piiResult: PIIDetectionResult?
    ) {
        let saveOrPin: CaptureQuickAction = screenshot.filePath == nil ? .save : .pin
        let alternateSaveOrPin: CaptureQuickAction = saveOrPin == .save ? .pin : .save
        let hasPII = piiResult?.screenshotID == screenshot.id
            && !(piiResult?.detections.isEmpty ?? true)
        primaryActions = hasPII
            ? [.copy, saveOrPin, .annotate, .redact]
            : [.copy, saveOrPin, .annotate]
        overflowActions = hasPII
            ? [alternateSaveOrPin, .share, .beautify, .markdown, .citation, .dismiss]
            : [alternateSaveOrPin, .share, .beautify, .redact, .markdown, .citation, .dismiss]
        showsPendingBadge = previewPhase == .enrichmentPending
        showsPIIBadge = hasPII
    }
}

struct QuickAccessOverlayView: View {
    let screenshot: ProcessedScreenshot
    let appState: AppState
    let onAction: (CaptureQuickAction) -> Void
    var onHoverChanged: ((Bool) -> Void)?

    private var presentation: QuickAccessPresentationModel {
        QuickAccessPresentationModel(
            screenshot: screenshot,
            previewPhase: appState.previewPhase(for: screenshot.id),
            piiResult: appState.piiResult(for: screenshot.id)
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(presentation.primaryActions, id: \.self) { action in
                QuickActionButton(
                    action: action,
                    isPrimaryPIIAction: action == .redact && presentation.showsPIIBadge
                ) {
                    onAction(action)
                }
            }

            Menu {
                ForEach(presentation.overflowActions, id: \.self) { action in
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.icon)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text("More")
                        .font(.system(size: 10, weight: .medium))
                    if presentation.showsPendingBadge {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                    }
                }
                .frame(width: 56, height: 34)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("quick-access-more")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(height: 52)
        .accessibilityIdentifier("quick-access-overlay")
        .onHover { hovering in
            onHoverChanged?(hovering)
        }
    }
}

private struct QuickActionButton: View {
    let action: CaptureQuickAction
    let isPrimaryPIIAction: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 1) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: action.icon)
                        .font(.system(size: 13, weight: .semibold))
                    if isPrimaryPIIAction {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: 4, y: -3)
                    }
                }
                Text(action.shortTitle)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 46, height: 34)
            .background(isHovered ? Color.primary.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help(action.title)
        .accessibilityLabel("\(action.title) screenshot")
        .accessibilityIdentifier("quick-action-\(action.accessibilityID)")
    }
}

private extension CaptureQuickAction {
    var title: String {
        switch self {
        case .copy: return "Copy"
        case .save: return "Save"
        case .markdown: return "Markdown"
        case .citation: return "Citation"
        case .annotate: return "Annotate"
        case .pin: return "Pin"
        case .beautify: return "Beautify"
        case .redact: return "Redact"
        case .share: return "Share"
        case .dismiss: return "Dismiss"
        }
    }

    var shortTitle: String {
        switch self {
        case .markdown:
            return "MD"
        case .citation:
            return "Quote"
        default:
            return title
        }
    }

    var icon: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .markdown: return "doc.text"
        case .citation: return "quote.closing"
        case .annotate: return "pencil.tip"
        case .pin: return "pin"
        case .beautify: return "sparkles"
        case .redact: return "eye.slash"
        case .share: return "square.and.arrow.up"
        case .dismiss: return "xmark.circle"
        }
    }

    var accessibilityID: String {
        switch self {
        case .copy: return "copy"
        case .save: return "save"
        case .markdown: return "markdown"
        case .citation: return "citation"
        case .annotate: return "annotate"
        case .pin: return "pin"
        case .beautify: return "beautify"
        case .redact: return "redact"
        case .share: return "share"
        case .dismiss: return "dismiss"
        }
    }
}
