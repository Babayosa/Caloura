import AppKit

final class ScreenSelectionView: NSView {
    static let captureHintText = "Click a display to capture  ·  ESC to cancel"

    var onScreenSelected: ((NSScreen) -> Void)?
    var onCancelled: (() -> Void)?
    weak var cursorController: CaptureCursorControlling?

    private let targetScreen: NSScreen
    private var isHighlighted: Bool = false
    // Visual styling
    private let normalOverlayColor = NSColor.black.withAlphaComponent(0.40)
    private let highlightOverlayColor = NSColor.black.withAlphaComponent(0.15)
    private let labelFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    private let hintFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private var crosshairPoint: CGPoint?

    var debugCaptureHintText: String {
        Self.captureHintText
    }

    init(frame: CGRect, screen: NSScreen) {
        self.targetScreen = screen
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            window.makeFirstResponder(self)
            window.acceptsMouseMovedEvents = true
            cursorController?.handleCursorUpdate()
            cursorController?.scheduleReprime()
            updateCrosshairFromCurrentMouseLocation()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        updateCrosshairFromCurrentMouseLocation()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isHighlighted {
            // Light overlay
            highlightOverlayColor.setFill()
            NSBezierPath(rect: bounds).fill()

            // Subtle white border inset from edges
            let borderRect = bounds.insetBy(dx: 4, dy: 4)
            let borderPath = NSBezierPath(rect: borderRect)
            borderPath.lineWidth = 3
            NSColor.white.withAlphaComponent(0.8).setStroke()
            borderPath.stroke()

            // Display name label
            drawDisplayName()

            // "Click to capture" hint
            drawClickHint()
        } else {
            // Darker overlay
            normalOverlayColor.setFill()
            NSBezierPath(rect: bounds).fill()

            // Display name label only
            drawDisplayName()
            drawClickHint()
        }
        drawCrosshair()
    }

    private func drawDisplayName() {
        let name = targetScreen.localizedName
        let nsText = name as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white
        ]
        let textSize = nsText.size(withAttributes: attributes)
        let padding: CGFloat = 14
        let pillWidth = textSize.width + padding * 2
        let pillHeight = textSize.height + padding

        let pillRect = CGRect(
            x: bounds.midX - pillWidth / 2,
            y: bounds.midY - pillHeight / 2 + (isHighlighted ? 12 : 0),
            width: pillWidth,
            height: pillHeight
        )

        // Dark pill background
        let bgPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
        NSColor.black.withAlphaComponent(0.70).setFill()
        bgPath.fill()

        // Text
        let textOrigin = CGPoint(
            x: pillRect.origin.x + padding,
            y: pillRect.origin.y + (pillHeight - textSize.height) / 2
        )
        nsText.draw(at: textOrigin, withAttributes: attributes)
    }

    private func drawClickHint() {
        let text = Self.captureHintText as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: hintFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        let textSize = text.size(withAttributes: attributes)
        let textOrigin = CGPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2 - 20
        )
        text.draw(at: textOrigin, withAttributes: attributes)
    }

    private func drawCrosshair() {
        guard let point = crosshairPoint, bounds.contains(point) else { return }
        let armLength = CaptureCrosshairMetrics.armLength
        let gap = CaptureCrosshairMetrics.gap
        drawCrosshairStroke(
            at: point,
            armLength: armLength,
            gap: gap,
            color: NSColor.black.withAlphaComponent(0.75),
            width: CaptureCrosshairMetrics.shadowLineWidth
        )
        drawCrosshairStroke(
            at: point,
            armLength: armLength,
            gap: gap,
            color: .white,
            width: CaptureCrosshairMetrics.strokeLineWidth
        )
    }

    private func drawCrosshairStroke(
        at point: CGPoint,
        armLength: CGFloat,
        gap: CGFloat,
        color: NSColor,
        width: CGFloat
    ) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = width
        path.move(to: CGPoint(x: point.x - armLength, y: point.y))
        path.line(to: CGPoint(x: point.x - gap, y: point.y))
        path.move(to: CGPoint(x: point.x + gap, y: point.y))
        path.line(to: CGPoint(x: point.x + armLength, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - armLength))
        path.line(to: CGPoint(x: point.x, y: point.y - gap))
        path.move(to: CGPoint(x: point.x, y: point.y + gap))
        path.line(to: CGPoint(x: point.x, y: point.y + armLength))
        color.setStroke()
        path.stroke()
    }

    // MARK: - Mouse Events

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        if window?.isKeyWindow == false { window?.makeKey() }
        updateCrosshair(with: event)
        cursorController?.handleCursorUpdate()
        cursorController?.scheduleReprime()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        updateCrosshair(with: event)
        cursorController?.handleCursorUpdate()
        cursorController?.scheduleReprime()
        onScreenSelected?(targetScreen)
    }

    override func mouseMoved(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        updateCrosshair(with: event)
        cursorController?.handleCursorUpdate()
        cursorController?.scheduleReprime()
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancelled?()
        }
    }

    private func updateCrosshair(with event: NSEvent) {
        crosshairPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    private func updateCrosshairFromCurrentMouseLocation() {
        guard let window else {
            crosshairPoint = nil
            needsDisplay = true
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        crosshairPoint = convert(windowPoint, from: nil)
        needsDisplay = true
    }
}
