import AppKit

final class ScreenSelectionOverlayWindow: NSPanel {
    var onScreenSelected: ((NSScreen) -> Void)?
    var onCancelled: (() -> Void)?
    private weak var cursorController: CaptureCursorControlling?

    convenience init(
        for screen: NSScreen,
        cursorController: CaptureCursorControlling?
    ) {
        self.init(
            contentRect: screen.frame,
            styleMask: .nonactivatingPanel,
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false
        self.level = CaptureOverlayWindow.overlayLevel
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hidesOnDeactivate = false
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
        self.cursorController = cursorController
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        primeCrosshair()
    }

    private func primeCrosshair() {
        guard let contentView else { return }
        makeFirstResponder(contentView)
        invalidateCursorRects(for: contentView)
        cursorController?.scheduleReprime()
    }

    /// Present a fullscreen-selection overlay on every screen.
    ///
    /// **Contract**: callers MUST have already invoked
    /// `cursorController.beginCrosshairSession()` (preceded by
    /// `resetCursorState()`) before calling this. `becomeKey()` fires
    /// synchronously inside `makeKeyAndOrderFront(nil)` below; if
    /// `cursorActive == false` at that moment, `primeCrosshair()`'s
    /// `scheduleReprime()` silently no-ops and the crosshair never appears.
    /// `FullscreenCaptureSessionCoordinator.present()` is the canonical caller
    /// and enforces this ordering.
    @MainActor
    static func showOnAllScreens(
        cursorController: CaptureCursorControlling? = nil,
        onScreenSelected: @escaping (NSScreen) -> Void,
        onCancelled: @escaping () -> Void
    ) -> [ScreenSelectionOverlayWindow] {
        let screens = orderedPresentationScreens()
        var overlays: [ScreenSelectionOverlayWindow] = []
        overlays.reserveCapacity(screens.count)

        for (index, screen) in screens.enumerated() {
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
            if index == 0 {
                overlay.makeKeyAndOrderFront(nil)
            } else {
                overlay.orderFrontRegardless()
            }
            overlays.append(overlay)
        }

        return overlays
    }

    private static func orderedPresentationScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard let mouseScreen = screens.first(where: { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }) else {
            return screens
        }

        return [mouseScreen] + screens.filter { $0 != mouseScreen }
    }
}
