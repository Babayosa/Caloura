import AppKit

final class CaptureOverlayWindow: NSWindow {
    var onRegionSelected: ((CGRect, NSScreen) -> Void)?
    var onCancelled: (() -> Void)?

    private var selectionView: RegionSelectionView?

    /// Set the frozen screenshot to display as background
    var frozenImage: CGImage? {
        didSet {
            selectionView?.frozenImage = frozenImage
        }
    }

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
        self.backgroundColor = NSColor.clear
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
        self.selectionView = selectionView
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func showOnAllScreens(
        frozenImages: [NSScreen: CGImage]? = nil,
        onRegionSelected: @escaping (CGRect, NSScreen) -> Void,
        onCancelled: @escaping () -> Void
    ) -> [CaptureOverlayWindow] {
        var windows: [CaptureOverlayWindow] = []

        // Activate app so the first click is a real mouseDown, not a window-activation click
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()

        for screen in NSScreen.screens {
            let overlay = CaptureOverlayWindow(for: screen)

            // Set frozen image for this screen if provided
            if let frozenImages = frozenImages, let image = frozenImages[screen] {
                overlay.frozenImage = image
            }

            overlay.onRegionSelected = { rect, screen in
                NSCursor.unhide()
                for w in windows {
                    w.onRegionSelected = nil
                    w.onCancelled = nil
                    w.close()
                }
                onRegionSelected(rect, screen)
            }
            overlay.onCancelled = {
                NSCursor.unhide()
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
