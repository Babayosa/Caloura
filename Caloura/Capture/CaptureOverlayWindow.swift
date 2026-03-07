import AppKit

@MainActor
final class CaptureOverlayWindow: NSPanel {
    var onRegionSelected: ((CGRect, NSScreen) -> Void)?
    var onCancelled: (() -> Void)?
    var onFirstMouseDown: (() -> Void)?

    private var selectionView: RegionSelectionView?
    private weak var cursorController: CaptureCursorControlling?

    /// Set the frozen screenshot to display as background
    var frozenImage: CGImage? {
        didSet {
            selectionView?.frozenImage = frozenImage
        }
    }

    var isDimmingSuppressed: Bool {
        get { selectionView?.isDimmingSuppressed ?? false }
        set { selectionView?.isDimmingSuppressed = newValue }
    }

    func revealFrozenImage(_ image: CGImage) {
        selectionView?.revealFrozenImage(image)
    }

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
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let selectionView = RegionSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        selectionView.cursorController = cursorController
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
        self.cursorController = cursorController
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        tearDownHandlers()
        super.close()
    }

    private func tearDownHandlers() {
        onRegionSelected = nil
        onCancelled = nil
        onFirstMouseDown = nil
        selectionView?.onRegionSelected = nil
        selectionView?.onCancelled = nil
        selectionView?.onFirstMouseDown = nil
    }

    static func showOnAllScreens(
        cursorController: CaptureCursorControlling? = nil,
        frozenImages: [NSScreen: CGImage]? = nil,
        suppressDimming: Bool = false,
        onRegionSelected: @escaping (CGRect, NSScreen) -> Void,
        onCancelled: @escaping () -> Void,
        onFirstMouseDown: (() -> Void)? = nil
    ) -> [CaptureOverlayWindow] {
        var windows: [CaptureOverlayWindow] = []

        for screen in NSScreen.screens {
            let overlay = CaptureOverlayWindow(
                for: screen,
                cursorController: cursorController
            )

            // Set frozen image for this screen if provided
            if let frozenImages = frozenImages, let image = frozenImages[screen] {
                overlay.frozenImage = image
            }

            if suppressDimming {
                overlay.isDimmingSuppressed = true
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
