import AppKit
import SwiftUI

@MainActor
final class ScrollProgressState: ObservableObject {
    @Published var progress = ScrollCaptureProgress(
        phase: .preparing,
        mode: .automatic,
        frameCount: 0,
        estimatedHeight: 0,
        status: "Preparing scroll capture",
        canSwitchToManual: false,
        canFinishManual: false
    )
}

@MainActor
final class ScrollProgressOverlay {
    private var panel: ScrollProgressPanel?
    private let state = ScrollProgressState()
    private var onCancel: (() -> Void)?
    private var onSwitchToManual: (() -> Void)?
    private var onFinish: (() -> Void)?

    func show(
        near region: CGRect,
        screen: NSScreen,
        onCancel: @escaping () -> Void,
        onSwitchToManual: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        dismiss()

        self.onCancel = onCancel
        self.onSwitchToManual = onSwitchToManual
        self.onFinish = onFinish
        state.progress = ScrollCaptureProgress(
            phase: .preparing,
            mode: .automatic,
            frameCount: 0,
            estimatedHeight: 0,
            status: "Preparing scroll capture",
            canSwitchToManual: false,
            canFinishManual: false
        )

        let panel = ScrollProgressPanel(state: state, overlay: self)
        self.panel = panel

        let panelSize = panel.frame.size
        let screenFrame = screen.frame
        let aboveY = region.origin.y + region.height + 10
        let belowY = region.origin.y - panelSize.height - 10
        let y = aboveY + panelSize.height <= screenFrame.maxY ? aboveY : belowY
        let x = max(
            screenFrame.minX + 12,
            min(region.midX - panelSize.width / 2, screenFrame.maxX - panelSize.width - 12)
        )

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    func update(_ progress: ScrollCaptureProgress) {
        state.progress = progress
    }

    func dismiss() {
        panel?.close()
        panel = nil
        onCancel = nil
        onSwitchToManual = nil
        onFinish = nil
    }

    func handleCancel() {
        let callback = onCancel
        dismiss()
        callback?()
    }

    func handleSwitchToManual() {
        onSwitchToManual?()
    }

    func handleFinish() {
        onFinish?()
    }
}

private final class ScrollProgressPanel: NSPanel {
    private weak var overlay: ScrollProgressOverlay?
    private let state: ScrollProgressState

    init(state: ScrollProgressState, overlay: ScrollProgressOverlay) {
        self.state = state
        self.overlay = overlay

        let size = NSSize(width: 460, height: 84)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false

        let hostView = NSHostingView(
            rootView: ScrollProgressView(
                state: state,
                onCancel: { [weak overlay] in
                    overlay?.handleCancel()
                },
                onSwitchToManual: { [weak overlay] in
                    overlay?.handleSwitchToManual()
                },
                onFinish: { [weak overlay] in
                    overlay?.handleFinish()
                }
            )
        )
        hostView.frame = contentRect(forFrameRect: frame)
        contentView = hostView
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            Task { @MainActor in
                overlay?.handleCancel()
            }
        case 36, 76:
            if state.progress.canFinishManual {
                Task { @MainActor in
                    overlay?.handleFinish()
                }
            } else {
                super.keyDown(with: event)
            }
        case 48:
            if state.progress.canSwitchToManual {
                Task { @MainActor in
                    overlay?.handleSwitchToManual()
                }
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }
}

private struct ScrollProgressView: View {
    @ObservedObject var state: ScrollProgressState
    let onCancel: () -> Void
    let onSwitchToManual: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.progress.phase.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(state.progress.status)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Text(state.progress.mode == .automatic ? "Auto" : "Manual")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 12) {
                Text("\(state.progress.frameCount) frames")
                    .foregroundStyle(.white.opacity(0.8))
                Text("~\(formatHeight(state.progress.estimatedHeight))")
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                if state.progress.canSwitchToManual {
                    Button("Switch to Manual") {
                        onSwitchToManual()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if state.progress.canFinishManual {
                    Button("Finish") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(
                state.progress.mode == .manual
                ? "Scroll in one direction only. Avoid rapid back-and-forth motion. Press Return when done."
                : "Tab switches to manual capture. Esc cancels."
            )
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.82))
        )
        .frame(width: 460, height: 84)
    }

    private func formatHeight(_ px: Int) -> String {
        if px >= 1000 {
            return String(format: "%.1fk px", Double(px) / 1000.0)
        }
        return "\(px) px"
    }
}
