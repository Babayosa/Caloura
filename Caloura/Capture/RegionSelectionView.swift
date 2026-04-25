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

    // Layer tree (z-order: background → dimming → border → labels)
    private let backgroundLayer = CALayer()
    private let dimmingLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let sizeContainer = CALayer()
    private let sizeTextLayer = CATextLayer()
    private let hintContainer = CALayer()
    private let hintTextLayer = CATextLayer()

    // Styling constants
    private let sizeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private let hintFont = NSFont.systemFont(ofSize: 13, weight: .medium)
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
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursorController?.handleCursorUpdate()
    }

    override func mouseEntered(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        cursorController?.scheduleReprime()
    }

    override func mouseMoved(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
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

    private func layoutHintLabel() {
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
        selectionStart = point
        selectionEnd = point
        isSelecting = true
        updateLayerVisibility()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionEnd = point
        updateLayerVisibility()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

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
}

// MARK: - Layer Setup

private extension RegionSelectionView {
    func setupBackgroundLayer(in root: CALayer) {
        backgroundLayer.contentsGravity = .resizeAspectFill
        backgroundLayer.frame = bounds
        backgroundLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        root.addSublayer(backgroundLayer)
    }

    func setupDimmingLayer(in root: CALayer) {
        dimmingLayer.fillColor = NSColor.clear.cgColor
        dimmingLayer.fillRule = .evenOdd
        dimmingLayer.frame = bounds
        root.addSublayer(dimmingLayer)
    }

    func setupBorderLayer(in root: CALayer) {
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.isHidden = true
        root.addSublayer(borderLayer)
    }

    func setupSizeLabel(in root: CALayer) {
        sizeContainer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        sizeContainer.cornerRadius = 4
        sizeContainer.isHidden = true
        root.addSublayer(sizeContainer)

        sizeTextLayer.font = sizeFont
        sizeTextLayer.fontSize = sizeFont.pointSize
        sizeTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        sizeTextLayer.alignmentMode = .center
        sizeTextLayer.truncationMode = .none
        sizeTextLayer.isWrapped = false
        sizeContainer.addSublayer(sizeTextLayer)
    }

    func setupHintLabel(in root: CALayer) {
        hintContainer.backgroundColor = NSColor.black.withAlphaComponent(0.50).cgColor
        hintContainer.cornerRadius = 8
        hintContainer.isHidden = false
        root.addSublayer(hintContainer)

        hintTextLayer.string = Self.hintText
        hintTextLayer.font = hintFont
        hintTextLayer.fontSize = hintFont.pointSize
        hintTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
        hintTextLayer.alignmentMode = .center
        hintTextLayer.truncationMode = .none
        hintTextLayer.isWrapped = false
        hintContainer.addSublayer(hintTextLayer)

        layoutHintLabel()
    }
}
