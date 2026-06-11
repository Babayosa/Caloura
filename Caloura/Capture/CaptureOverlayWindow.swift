import AppKit
import CoreGraphics

@MainActor
final class CaptureOverlayWindow: NSPanel {
    static let overlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.overlayWindow))
    )

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
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.excludeFromScreenSharing()
        self.isReleasedWhenClosed = false
        self.level = Self.overlayLevel
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

    override func becomeKey() {
        super.becomeKey()
        primeCrosshair()
    }

    override func close() {
        tearDownHandlers()
        super.close()
    }

    private func primeCrosshair() {
        guard let contentView else { return }
        // Re-assert first responder so mouseMoved keeps firing after the panel
        // regains key. Pool reuse + Mission Control / Spotlight resignations
        // can leave the contentView demoted.
        makeFirstResponder(contentView)
        invalidateCursorRects(for: contentView)
        cursorController?.handleCursorUpdate()
        cursorController?.scheduleReprime()
    }

    func tearDownHandlers() {
        onRegionSelected = nil
        onCancelled = nil
        onFirstMouseDown = nil
        // Bridge closures on selectionView are permanent — they delegate
        // through the window's optional callbacks above, which are nil-safe.
    }

    func resetForReuse(cursorController: CaptureCursorControlling?) {
        tearDownHandlers()
        self.cursorController = cursorController
        selectionView?.resetForReuse(cursorController: cursorController)
        // viewDidMoveToWindow does not re-fire on pool reuse (the view stayed
        // in this window). Re-assert first responder + acceptsMouseMovedEvents
        // so mouseMoved keeps firing across captures.
        if let selectionView {
            makeFirstResponder(selectionView)
        }
        acceptsMouseMovedEvents = true
        cursorController?.handleCursorUpdate()
    }

    func setInitialCrosshairLocation(globalPoint: CGPoint) {
        selectionView?.setInitialCrosshairLocation(globalPoint: globalPoint)
    }

    static func orderedPresentationScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard let mouseScreen = screens.first(where: { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }) else {
            return screens
        }

        return [mouseScreen] + screens.filter { $0 != mouseScreen }
    }
}
