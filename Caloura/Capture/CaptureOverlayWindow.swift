import AppKit

final class CaptureOverlayWindow: NSWindow {
    var onRegionSelected: ((CGRect, NSScreen) -> Void)?
    var onCancelled: (() -> Void)?
    var onFirstMouseDown: (() -> Void)?

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

        let selectionView = RegionSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        selectionView.autoresizingMask = [.width, .height]
        selectionView.onRegionSelected = { [weak self] rect in
            guard let self = self else { return }
            // Rect is in screen-local coordinates (origin at screen frame)
            self.onRegionSelected?(rect, screen)
        }
        selectionView.onCancelled = { [weak self] in
            self?.onCancelled?()
        }
        selectionView.onFirstMouseDown = { [weak self] in
            self?.onFirstMouseDown?()
        }
        self.selectionView = selectionView
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func showOnAllScreens(
        frozenImages: [NSScreen: CGImage]? = nil,
        onRegionSelected: @escaping (CGRect, NSScreen) -> Void,
        onCancelled: @escaping () -> Void,
        onFirstMouseDown: (() -> Void)? = nil
    ) -> [CaptureOverlayWindow] {
        var windows: [CaptureOverlayWindow] = []

        // Activate app so the first click is a real mouseDown, not a window-activation click
        NSApp.activate()

        for screen in NSScreen.screens {
            let overlay = CaptureOverlayWindow(for: screen)

            // Set frozen image for this screen if provided
            if let frozenImages = frozenImages, let image = frozenImages[screen] {
                overlay.frozenImage = image
            }

            let closeAll = {
                for item in windows {
                    item.onRegionSelected = nil
                    item.onCancelled = nil
                    item.onFirstMouseDown = nil
                    item.close()
                }
            }
            overlay.onRegionSelected = { rect, screen in
                closeAll()
                onRegionSelected(rect, screen)
            }
            overlay.onCancelled = {
                closeAll()
                onCancelled()
            }
            overlay.onFirstMouseDown = onFirstMouseDown

            // Break retain cycle: nil out closures when the window closes
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: overlay,
                queue: .main
            ) { [weak overlay] _ in
                overlay?.onRegionSelected = nil
                overlay?.onCancelled = nil
                overlay?.onFirstMouseDown = nil
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

        // Re-assert crosshair after activation completes.
        // NSApp.activate() is async — when activation finishes, AppKit
        // recalculates cursor rects and may briefly reset to arrow.
        // This one-shot observer fires at that exact moment to fix it.
        var activationObserver: NSObjectProtocol?
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            NSCursor.crosshair.set()
            if let obs = activationObserver {
                NotificationCenter.default.removeObserver(obs)
                activationObserver = nil
            }
        }

        return windows
    }
}
