import AppKit

final class RegionSelectionView: NSView {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var selectionStart: NSPoint?
    private var selectionEnd: NSPoint?
    private var isSelecting = false
    private var currentMouseLocation: NSPoint?
    private var trackingArea: NSTrackingArea?

    // Crosshair styling
    private let crosshairColor = NSColor.white.withAlphaComponent(0.45)
    private let crosshairWidth: CGFloat = 0.5

    // Selection styling
    private let selectionBorderColor = NSColor.white
    private let overlayColor = NSColor.black.withAlphaComponent(0.40)
    private let idleOverlayColor = NSColor.black.withAlphaComponent(0.15)
    private let sizeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private var cursorHidden = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            window.makeFirstResponder(self)
            window.acceptsMouseMovedEvents = true
            if !cursorHidden {
                NSCursor.hide()
                cursorHidden = true
            }
        } else if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    override func removeFromSuperview() {
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        super.removeFromSuperview()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let rect = normalizedRect(from: start, to: end)

            // Darkened overlay with cutout
            let path = NSBezierPath(rect: bounds)
            let cutout = NSBezierPath(rect: rect)
            path.append(cutout.reversed)
            overlayColor.setFill()
            path.fill()

            // Selection border — thin white
            selectionBorderColor.withAlphaComponent(0.9).setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 1
            borderPath.stroke()

            // Size label
            drawSizeLabel(for: rect)
        } else {
            // Subtle idle overlay
            idleOverlayColor.setFill()
            NSBezierPath(rect: bounds).fill()

            // Hint when not selecting
            drawHintLabel()
        }

        // Crosshair on top
        if let mouseLocation = currentMouseLocation {
            drawCrosshair(at: mouseLocation)
        }
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

    override func mouseMoved(with event: NSEvent) {
        currentMouseLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentMouseLocation = point
        selectionStart = point
        selectionEnd = point
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentMouseLocation = point
        selectionEnd = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentMouseLocation = point

        guard isSelecting, let start = selectionStart else {
            needsDisplay = true
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
            needsDisplay = true
        }

        // Re-assert first responder so mouseMoved keeps firing
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancelled?()
        }
    }

    // MARK: - Crosshair

    private func drawCrosshair(at point: NSPoint) {
        crosshairColor.setStroke()

        // Horizontal line — full width
        let hLine = NSBezierPath()
        hLine.lineWidth = crosshairWidth
        hLine.move(to: NSPoint(x: bounds.minX, y: point.y))
        hLine.line(to: NSPoint(x: bounds.maxX, y: point.y))
        hLine.stroke()

        // Vertical line — full height
        let vLine = NSBezierPath()
        vLine.lineWidth = crosshairWidth
        vLine.move(to: NSPoint(x: point.x, y: bounds.minY))
        vLine.line(to: NSPoint(x: point.x, y: bounds.maxY))
        vLine.stroke()
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
