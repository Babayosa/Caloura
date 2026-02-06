import AppKit
import Carbon.HIToolbox

final class RegionSelectionView: NSView {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?
    var onFirstMouseDown: (() -> Void)?

    /// Frozen screenshot to display as background (enables menu capture)
    var frozenImage: CGImage? {
        didSet { needsDisplay = true }
    }

    private var selectionStart: NSPoint?
    private var selectionEnd: NSPoint?
    private var isSelecting = false
    private var hasSentFirstMouseDown = false
    private var cursorPushed = false
    private var trackingArea: NSTrackingArea?

    // Selection styling
    private let selectionBorderColor = NSColor.white
    private let sizeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            window.makeFirstResponder(self)
            window.acceptsMouseMovedEvents = true
            NSCursor.crosshair.push()
            cursorPushed = true
        } else if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
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
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw frozen screenshot as background (enables menu capture)
        if let frozenImage = frozenImage {
            let context = NSGraphicsContext.current?.cgContext
            context?.draw(frozenImage, in: bounds)
        }

        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let rect = normalizedRect(from: start, to: end)

            // Dim area outside selection when frozen image is shown
            if frozenImage != nil {
                drawDimmingMask(excluding: rect)
            }

            // Selection border — thin white
            selectionBorderColor.withAlphaComponent(0.9).setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 1
            borderPath.stroke()

            // Size label
            drawSizeLabel(for: rect)
        } else {
            // Show hint label
            drawHintLabel()
        }

    }

    private func drawDimmingMask(excluding rect: CGRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()

        // Draw four rectangles around the selection
        // Top
        NSBezierPath(rect: CGRect(x: 0, y: rect.maxY, width: bounds.width, height: bounds.maxY - rect.maxY)).fill()
        // Bottom
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: rect.minY)).fill()
        // Left
        NSBezierPath(rect: CGRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height)).fill()
        // Right
        let rightRect = CGRect(
            x: rect.maxX, y: rect.minY,
            width: bounds.maxX - rect.maxX, height: rect.height
        )
        NSBezierPath(rect: rightRect).fill()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2.0
        let sizeText = "\(Int(rect.width * scale)) \u{00D7} \(Int(rect.height * scale))" as NSString

        let attributes: [NSAttributedString.Key: Any] = [
            .font: sizeFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]

        let textSize = sizeText.size(withAttributes: attributes)
        let padding: CGFloat = 6
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding

        // Position below selection rect
        var labelOrigin = CGPoint(
            x: rect.midX - labelWidth / 2,
            y: rect.minY - labelHeight - 6
        )

        // Flip above if off-screen below
        if labelOrigin.y < 4 {
            labelOrigin.y = rect.maxY + 6
        }

        // Clamp horizontal
        labelOrigin.x = max(4, min(labelOrigin.x, bounds.maxX - labelWidth - 4))

        let labelRect = CGRect(origin: labelOrigin, size: CGSize(width: labelWidth, height: labelHeight))

        let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        bgPath.fill()

        let textOrigin = CGPoint(
            x: labelRect.origin.x + padding,
            y: labelRect.origin.y + (labelHeight - textSize.height) / 2
        )
        sizeText.draw(at: textOrigin, withAttributes: attributes)
    }

    private func drawHintLabel() {
        let text = "Drag to select  \u{00B7}  ESC to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 10
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding

        let labelRect = CGRect(
            x: bounds.midX - labelWidth / 2,
            y: 24,
            width: labelWidth,
            height: labelHeight
        )
        let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.50).setFill()
        bgPath.fill()

        let textOrigin = CGPoint(
            x: labelRect.origin.x + padding,
            y: labelRect.origin.y + (labelHeight - textSize.height) / 2
        )
        text.draw(at: textOrigin, withAttributes: attributes)
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
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionEnd = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        guard isSelecting, let start = selectionStart else {
            needsDisplay = true
            return
        }
        isSelecting = false

        let rect = normalizedRect(from: start, to: point)

        // Minimum selection size (10x10)
        if rect.width >= 10 && rect.height >= 10 {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
            onRegionSelected?(rect)
        } else {
            // Too small, reset
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
        }

        // Re-assert first responder so mouseMoved keeps firing
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
            onCancelled?()
        }
    }

    // MARK: - Helpers

    private func normalizedRect(from start: NSPoint, to end: NSPoint) -> CGRect {
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
