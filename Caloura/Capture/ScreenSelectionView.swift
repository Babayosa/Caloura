import AppKit

final class ScreenSelectionView: NSView {
    var onScreenSelected: ((NSScreen) -> Void)?
    var onCancelled: (() -> Void)?
    weak var cursorController: CaptureCursorControlling?

    private let targetScreen: NSScreen
    private var isHighlighted: Bool = false
    private var trackingArea: NSTrackingArea?

    // Visual styling
    private let normalOverlayColor = NSColor.black.withAlphaComponent(0.40)
    private let highlightOverlayColor = NSColor.black.withAlphaComponent(0.15)
    private let labelFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    private let hintFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    init(frame: CGRect, screen: NSScreen) {
        self.targetScreen = screen
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            window.makeFirstResponder(self)
            window.acceptsMouseMovedEvents = true
            cursorController?.reassertCrosshair()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursorController?.reassertCrosshair()
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
        let text = "Click a display to capture  ·  ESC to cancel" as NSString
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

    // MARK: - Mouse Events

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        cursorController?.reassertCrosshair()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        cursorController?.reassertCrosshair()
        onScreenSelected?(targetScreen)
    }

    override func mouseMoved(with event: NSEvent) {
        cursorController?.reassertCrosshair()
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancelled?()
        }
    }
}
