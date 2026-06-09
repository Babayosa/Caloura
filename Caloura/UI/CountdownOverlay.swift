import AppKit
import SwiftUI

// MARK: - Countdown State

@MainActor
@Observable
final class CountdownState {
    var count: Int = 0
}

// MARK: - Countdown Overlay (Singleton)

@MainActor
final class CountdownOverlay {
    static let shared = CountdownOverlay()

    private var panel: CountdownPanel?
    private let state = CountdownState()
    private var onCancel: (() -> Void)?

    private init() {}

    func show(seconds: Int, onCancel: @escaping () -> Void) {
        dismiss()

        self.onCancel = onCancel
        state.count = seconds

        let panel = CountdownPanel(state: state, overlay: self)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func updateCount(_ count: Int) {
        state.count = count
    }

    func dismiss() {
        panel?.close()
        panel = nil
        onCancel = nil
    }

    func handleCancel() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}

// MARK: - NSPanel Subclass

private final class CountdownPanel: NSPanel {
    private weak var overlay: CountdownOverlay?

    init(state: CountdownState, overlay: CountdownOverlay) {
        self.overlay = overlay

        let size = NSSize(width: 160, height: 160)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        excludeFromScreenSharing()
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false

        let hostView = NSHostingView(rootView: CountdownOverlayView(state: state))
        hostView.frame = contentRect(forFrameRect: frame)
        contentView = hostView

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.midY - size.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            Task { @MainActor in
                overlay?.handleCancel()
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - SwiftUI View

private struct CountdownOverlayView: View {
    var state: CountdownState

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 120, height: 120)

                Text("\(state.count)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            Text("ESC to cancel")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 160, height: 160)
    }
}
