import AppKit

final class CaptureOverlayWindow: NSWindow {
    var onRegionSelected: ((CGRect, NSScreen) -> Void)?
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

        let selectionView = RegionSelectionView(frame: screen.frame)
        selectionView.onRegionSelected = { [weak self] rect in
            guard let self = self else { return }
            // Convert from view coordinates to screen coordinates
            let screenRect = CGRect(
                x: self.frame.origin.x + rect.origin.x,
                y: self.frame.origin.y + rect.origin.y,
                width: rect.width,
                height: rect.height
            )
            self.onRegionSelected?(screenRect, screen)
        }
        selectionView.onCancelled = { [weak self] in
            self?.onCancelled?()
        }
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func showOnAllScreens(
        onRegionSelected: @escaping (CGRect, NSScreen) -> Void,
        onCancelled: @escaping () -> Void
    ) -> [CaptureOverlayWindow] {
        var windows: [CaptureOverlayWindow] = []

        for screen in NSScreen.screens {
            let overlay = CaptureOverlayWindow(for: screen)
            overlay.onRegionSelected = { rect, screen in
                // Close all overlays and break retain cycle
                for w in windows {
                    w.onRegionSelected = nil
                    w.onCancelled = nil
                    w.close()
                }
                onRegionSelected(rect, screen)
            }
            overlay.onCancelled = {
                for w in windows {
                    w.onRegionSelected = nil
                    w.onCancelled = nil
                    w.close()
                }
                onCancelled()
            }
            overlay.makeKeyAndOrderFront(nil)
            windows.append(overlay)
        }

        // Make the overlay on the current screen key
        if let mouseScreen = NSScreen.screens.first(where: { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }) {
            windows.first { $0.screen == mouseScreen }?.makeKey()
        }

        return windows
    }
}
