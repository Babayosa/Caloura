import AppKit

final class RegionSelectionView: NSView {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var selectionStart: NSPoint?
    private var selectionEnd: NSPoint?
    private var isSelecting = false

    private let crosshairColor = NSColor.white
    private let selectionBorderColor = NSColor.systemBlue
    private let selectionFillColor = NSColor.systemBlue.withAlphaComponent(0.1)
    private let overlayColor = NSColor.black.withAlphaComponent(0.3)
    private let sizeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.push()
    }

    override func removeFromSuperview() {
        NSCursor.pop()
        super.removeFromSuperview()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let rect = normalizedRect(from: start, to: end)

            // Draw darkened overlay with cutout
            let path = NSBezierPath(rect: bounds)
            let cutout = NSBezierPath(rect: rect)
            path.append(cutout.reversed)
            overlayColor.setFill()
            path.fill()

            // Draw selection border
            selectionBorderColor.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 1.5
            borderPath.stroke()

            // Draw selection fill
            selectionFillColor.setFill()
            NSBezierPath(rect: rect).fill()

            // Draw size label
            drawSizeLabel(for: rect)
        } else {
            // Draw subtle overlay when not selecting
            NSColor.black.withAlphaComponent(0.15).setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2.0
        let sizeText = "\(Int(rect.width * scale)) x \(Int(rect.height * scale))" as NSString

        let attributes: [NSAttributedString.Key: Any] = [
            .font: sizeFont,
            .foregroundColor: NSColor.white
        ]

        let textSize = sizeText.size(withAttributes: attributes)
        let padding: CGFloat = 6
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding

        // Position label below the selection rect
        var labelOrigin = CGPoint(
            x: rect.midX - labelWidth / 2,
            y: rect.minY - labelHeight - 8
        )

        // If label would go off screen, put it above
        if labelOrigin.y < 0 {
            labelOrigin.y = rect.maxY + 8
        }

        let labelRect = CGRect(origin: labelOrigin, size: CGSize(width: labelWidth, height: labelHeight))

        // Background pill
        let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        bgPath.fill()

        // Text
        let textOrigin = CGPoint(
            x: labelRect.origin.x + padding,
            y: labelRect.origin.y + (labelHeight - textSize.height) / 2
        )
        sizeText.draw(at: textOrigin, withAttributes: attributes)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectionStart = point
        selectionEnd = point
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        selectionEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting, let start = selectionStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        isSelecting = false

        let rect = normalizedRect(from: start, to: end)

        // Minimum selection size (10x10)
        if rect.width >= 10 && rect.height >= 10 {
            onRegionSelected?(rect)
        } else {
            // Too small, reset
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
        }
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
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
