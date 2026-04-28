import AppKit
import Carbon.HIToolbox
import QuartzCore

final class RegionSelectionView: NSView {
    static let hintText = "Drag to select  \u{00B7}  ESC to cancel"

    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?
    var onFirstMouseDown: (() -> Void)?
    weak var cursorController: CaptureCursorControlling?

    /// Frozen screenshot to display as background (enables menu capture)
    var frozenImage: CGImage? {
        didSet {
            backgroundLayer.contents = frozenImage
        }
    }

    /// When true, dimming and hint are hidden (used during two-phase overlay
    /// reveal while frozen images are still loading).
    var isDimmingSuppressed = false {
        didSet { applyDimmingSuppression() }
    }

    private var selectionStart: NSPoint?
    private var selectionEnd: NSPoint?
    private var isSelecting = false
    private var hasSentFirstMouseDown = false
    private var initialGlobalCrosshairPoint: CGPoint?

    let backgroundLayer = CALayer()
    let dimmingLayer = CAShapeLayer()
    let borderLayer = CAShapeLayer()
    let sizeContainer = CALayer()
    let sizeTextLayer = CATextLayer()
    let hintContainer = CALayer()
    let hintTextLayer = CATextLayer()
    let crosshairOverlay = CaptureCrosshairOverlayLayer()

    // Styling constants
    let sizeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    let hintFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let labelPadding: CGFloat = 6
    private let hintPadding: CGFloat = 10

    var debugHintVisible: Bool {
        !hintContainer.isHidden
    }

    var debugHintText: String {
        Self.hintText
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Layer-hosting view: we manage the entire layer tree.
        // This avoids the AppKit restriction against adding sublayers
        // to a layer-backed view's automatically managed layer.
        let rootLayer = CALayer()
        self.layer = rootLayer
        self.wantsLayer = true

        setupBackgroundLayer(in: rootLayer)
        setupDimmingLayer(in: rootLayer)
        setupBorderLayer(in: rootLayer)
        setupSizeLabel(in: rootLayer)
        setupHintLabel(in: rootLayer)
        crosshairOverlay.add(to: rootLayer)

        updateLayerVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func resetForReuse(cursorController: CaptureCursorControlling?) {
        self.cursorController = cursorController
        selectionStart = nil
        selectionEnd = nil
        isSelecting = false
        hasSentFirstMouseDown = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenImage = nil
        isDimmingSuppressed = false
        updateLayerVisibility()
        CATransaction.commit()
        updateCrosshairFromInitialLocation()
    }

    func revealFrozenImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenImage = image
        isDimmingSuppressed = false
        updateLayerVisibility()
        CATransaction.commit()
        announceCaptureOverlay()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        dimmingLayer.frame = bounds
        layoutHintLabel()
        crosshairOverlay.updateBounds(bounds, scale: window?.backingScaleFactor ?? 2.0)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            window.makeFirstResponder(self)
            window.acceptsMouseMovedEvents = true
            cursorController?.handleCursorUpdate()
            cursorController?.scheduleReprime()
            applyBackingScale(window.backingScaleFactor)
            updateCrosshairFromInitialLocation()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        window.map { applyBackingScale($0.backingScaleFactor) }
    }

    private func applyBackingScale(_ scale: CGFloat) {
        [backgroundLayer, sizeTextLayer, hintTextLayer].forEach { $0.contentsScale = scale }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        ))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: CaptureCursorStyle.transparentCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursorController?.handleCursorUpdate()
    }

    override func mouseEntered(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        cursorController?.handleCursorUpdate()
        cursorController?.scheduleReprime()
    }

    override func mouseMoved(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        updateCrosshair(with: event)
        cursorController?.handleCursorUpdate()
        cursorController?.scheduleReprime()
    }

    // MARK: - Layer Updates

    private func applyDimmingSuppression() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimmingLayer.opacity = isDimmingSuppressed ? 0 : 1
        hintContainer.opacity = isDimmingSuppressed ? 0 : 1
        CATransaction.commit()
    }

    private func updateLayerVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let rect = normalizedRect(from: start, to: end)
            dimmingLayer.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor

            // Dimming (only when frozen image is present)
            if frozenImage != nil {
                let combined = CGMutablePath()
                combined.addRect(bounds)
                combined.addRect(rect)
                dimmingLayer.path = combined
            } else {
                dimmingLayer.path = CGPath(rect: bounds, transform: nil)
            }

            // Border
            borderLayer.path = CGPath(rect: rect, transform: nil)
            borderLayer.isHidden = false

            // Size label
            layoutSizeLabel(for: rect)
            sizeContainer.isHidden = false

            // Hide hint
            hintContainer.isHidden = true
        } else {
            dimmingLayer.fillColor = NSColor.clear.cgColor
            dimmingLayer.path = CGPath(rect: bounds, transform: nil)
            borderLayer.path = nil
            borderLayer.isHidden = true
            sizeContainer.isHidden = true
            hintContainer.isHidden = false
        }
    }

    private func layoutSizeLabel(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2.0
        let text = "\(Int(rect.width * scale)) \u{00D7} \(Int(rect.height * scale))"
        sizeTextLayer.string = text

        let textSize = (text as NSString).size(
            withAttributes: [.font: sizeFont]
        )
        let containerWidth = textSize.width + labelPadding * 2
        let containerHeight = textSize.height + labelPadding

        // Position below selection rect
        var originX = rect.midX - containerWidth / 2
        var originY = rect.minY - containerHeight - 6

        // Flip above if off-screen below
        if originY < 4 {
            originY = rect.maxY + 6
        }

        // Clamp horizontal
        originX = max(4, min(originX, bounds.maxX - containerWidth - 4))

        sizeContainer.frame = CGRect(
            x: originX, y: originY,
            width: containerWidth, height: containerHeight
        )
        sizeTextLayer.frame = CGRect(
            x: labelPadding,
            y: (containerHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
    }

    func layoutHintLabel() {
        let text = Self.hintText
        let textSize = (text as NSString).size(
            withAttributes: [.font: hintFont]
        )
        let containerWidth = textSize.width + hintPadding * 2
        let containerHeight = textSize.height + hintPadding

        hintContainer.frame = CGRect(
            x: bounds.midX - containerWidth / 2,
            y: 24,
            width: containerWidth,
            height: containerHeight
        )
        hintTextLayer.frame = CGRect(
            x: hintPadding,
            y: (containerHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        if !hasSentFirstMouseDown {
            hasSentFirstMouseDown = true
            onFirstMouseDown?()
        }
        let point = convert(event.locationInWindow, from: nil)
        crosshairOverlay.update(to: point, in: bounds)
        selectionStart = point
        selectionEnd = point
        isSelecting = true
        updateLayerVisibility()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        crosshairOverlay.update(to: point, in: bounds)
        selectionEnd = point
        updateLayerVisibility()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        crosshairOverlay.update(to: point, in: bounds)

        guard isSelecting, let start = selectionStart else {
            return
        }
        isSelecting = false

        let rect = normalizedRect(from: start, to: point)

        // Minimum selection size (10x10)
        if rect.width >= 10 && rect.height >= 10 {
            onRegionSelected?(rect)
        } else {
            // Too small, reset
            selectionStart = nil
            selectionEnd = nil
            updateLayerVisibility()
        }

        // Re-assert first responder so mouseMoved keeps firing
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancelled?()
        }
    }

    private func normalizedRect(from start: NSPoint, to end: NSPoint) -> CGRect {
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func updateCrosshair(with event: NSEvent) {
        crosshairOverlay.update(to: convert(event.locationInWindow, from: nil), in: bounds)
    }

    func setInitialCrosshairLocation(globalPoint: CGPoint) {
        initialGlobalCrosshairPoint = globalPoint
        updateCrosshairFromInitialLocation()
    }

    private func updateCrosshairFromInitialLocation() {
        guard let window else {
            crosshairOverlay.hide()
            return
        }
        let globalPoint = initialGlobalCrosshairPoint ?? NSEvent.mouseLocation
        let windowPoint = CGPoint(
            x: globalPoint.x - window.frame.minX,
            y: globalPoint.y - window.frame.minY
        )
        crosshairOverlay.update(to: convert(windowPoint, from: nil), in: bounds)
    }
}
