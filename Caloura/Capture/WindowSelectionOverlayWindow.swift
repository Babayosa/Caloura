import AppKit

final class WindowSelectionOverlayWindow: NSWindow {
    var onWindowSelected: ((CaptureWindow) -> Void)?
    var onCancelled: (() -> Void)?

    convenience init(for screen: NSScreen, windows: [CaptureWindow]) {
        self.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let selectionView = WindowSelectionView(
            frame: screen.frame,
            windows: windows,
            screen: screen
        )
        selectionView.onWindowSelected = { [weak self] window in
            self?.onWindowSelected?(window)
        }
        selectionView.onCancelled = { [weak self] in
            self?.onCancelled?()
        }
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @MainActor
    static func showOnAllScreens(
        windows: [CaptureWindow],
        onWindowSelected: @escaping (CaptureWindow) -> Void,
        onCancelled: @escaping () -> Void
    ) -> [WindowSelectionOverlayWindow] {
        var overlays: [WindowSelectionOverlayWindow] = []

        for screen in NSScreen.screens {
            let overlay = WindowSelectionOverlayWindow(for: screen, windows: windows)
            overlay.onWindowSelected = { window in
                // Close all overlays and break retain cycle
                for w in overlays {
                    w.onWindowSelected = nil
                    w.onCancelled = nil
                    w.close()
                }
                onWindowSelected(window)
            }
            overlay.onCancelled = {
                for w in overlays {
                    w.onWindowSelected = nil
                    w.onCancelled = nil
                    w.close()
                }
                onCancelled()
            }
            overlay.makeKeyAndOrderFront(nil)
            overlays.append(overlay)
        }

        // Make the overlay on the screen with the mouse key
        if let mouseScreen = NSScreen.screens.first(where: { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }) {
            overlays.first { $0.screen == mouseScreen }?.makeKey()
        }

        return overlays
    }
}
