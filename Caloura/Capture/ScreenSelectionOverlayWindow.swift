import AppKit

final class ScreenSelectionOverlayWindow: NSWindow {
    var onScreenSelected: ((NSScreen) -> Void)?
    var onCancelled: (() -> Void)?

    convenience init(
        for screen: NSScreen,
        cursorController: CaptureCursorControlling?
    ) {
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

        let selectionView = ScreenSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screen: screen
        )
        selectionView.cursorController = cursorController
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
        cursorController: CaptureCursorControlling? = nil,
        onScreenSelected: @escaping (NSScreen) -> Void,
        onCancelled: @escaping () -> Void
    ) -> [ScreenSelectionOverlayWindow] {
        var overlays: [ScreenSelectionOverlayWindow] = []

        for screen in NSScreen.screens {
            let overlay = ScreenSelectionOverlayWindow(
                for: screen,
                cursorController: cursorController
            )
            let closeAll = {
                for item in overlays {
                    item.onScreenSelected = nil
                    item.onCancelled = nil
                    item.close()
                }
            }
            overlay.onScreenSelected = { selectedScreen in
                closeAll()
                onScreenSelected(selectedScreen)
            }
            overlay.onCancelled = {
                closeAll()
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
