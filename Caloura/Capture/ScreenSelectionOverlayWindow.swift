import AppKit

final class ScreenSelectionOverlayWindow: NSWindow {
    var onScreenSelected: ((NSScreen) -> Void)?
    var onCancelled: (() -> Void)?

    convenience init(for screen: NSScreen) {
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

        let selectionView = ScreenSelectionView(frame: screen.frame, screen: screen)
        selectionView.onScreenSelected = { [weak self] screen in
            self?.onScreenSelected?(screen)
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
        onScreenSelected: @escaping (NSScreen) -> Void,
        onCancelled: @escaping () -> Void
    ) -> [ScreenSelectionOverlayWindow] {
        var overlays: [ScreenSelectionOverlayWindow] = []

        for screen in NSScreen.screens {
            let overlay = ScreenSelectionOverlayWindow(for: screen)
            overlay.onScreenSelected = { selectedScreen in
                // Close all overlays and break retain cycles
                for w in overlays {
                    w.onScreenSelected = nil
                    w.onCancelled = nil
                    w.close()
                }
                onScreenSelected(selectedScreen)
            }
            overlay.onCancelled = {
                for w in overlays {
                    w.onScreenSelected = nil
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
