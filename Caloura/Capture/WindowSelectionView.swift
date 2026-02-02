import AppKit

final class WindowSelectionView: NSView {
    var onWindowSelected: ((CaptureWindow) -> Void)?
    var onCancelled: (() -> Void)?

    private let windows: [CaptureWindow]
    private let targetScreen: NSScreen
    private var highlightedWindow: CaptureWindow?

    // Visual styling
    private let overlayColor = NSColor.black.withAlphaComponent(0.3)
    private let highlightBorderColor = NSColor.systemBlue
    private let highlightFillColor = NSColor.systemBlue.withAlphaComponent(0.08)
    private let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(frame: CGRect, windows: [CaptureWindow], screen: NSScreen) {
        self.windows = windows
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
        }
    }

    // MARK: - Coordinate Conversion

    /// Convert a CG-coordinate window frame (top-left origin) to this view's
    /// coordinate system (NSView bottom-left origin, view-local).
    private func viewRect(for cgFrame: CGRect) -> CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return .zero }

        // CG top-left → AppKit global bottom-left
        let appKitGlobalY = primaryHeight - cgFrame.origin.y - cgFrame.height

        // AppKit global → view-local (view origin matches screen origin)
        let localX = cgFrame.origin.x - targetScreen.frame.origin.x
        let localY = appKitGlobalY - targetScreen.frame.origin.y

        return CGRect(x: localX, y: localY, width: cgFrame.width, height: cgFrame.height)
    }

    // MARK: - Hit Testing

    private func windowAtPoint(_ point: NSPoint) -> CaptureWindow? {
        // Iterate front-to-back (windows are already in z-order from the system)
        for window in windows {
            let rect = viewRect(for: window.frame)
            if rect.contains(point) {
                return window
            }
        }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let highlighted = highlightedWindow {
            let rect = viewRect(for: highlighted.frame)

            // Darkened overlay with cutout for highlighted window
            let overlayPath = NSBezierPath(rect: bounds)
            let cutout = NSBezierPath(rect: rect)
            overlayPath.append(cutout.reversed)
            overlayColor.setFill()
            overlayPath.fill()

            // Blue border around highlighted window
            highlightBorderColor.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 2.0
            borderPath.stroke()

            // Subtle fill inside
            highlightFillColor.setFill()
            NSBezierPath(rect: rect).fill()

            // App name label above the window
            drawLabel(highlighted.appName, above: rect)
        } else {
            // No window highlighted — draw uniform overlay
            overlayColor.setFill()
            NSBezierPath(rect: bounds).fill()
        }

        drawHintLabel()
    }

    private func drawLabel(_ text: String, above rect: CGRect) {
        guard !text.isEmpty else { return }

        let nsText = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white
        ]
        let textSize = nsText.size(withAttributes: attributes)
        let padding: CGFloat = 8
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding

        var labelOrigin = CGPoint(
            x: rect.midX - labelWidth / 2,
            y: rect.maxY + 6
        )

        // Clamp to view bounds
        labelOrigin.x = max(4, min(labelOrigin.x, bounds.maxX - labelWidth - 4))
        if labelOrigin.y + labelHeight > bounds.maxY - 4 {
            labelOrigin.y = rect.minY - labelHeight - 6
        }

        let labelRect = CGRect(origin: labelOrigin, size: CGSize(width: labelWidth, height: labelHeight))

        // Background pill
        let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.75).setFill()
        bgPath.fill()

        // Text
        let textOrigin = CGPoint(
            x: labelRect.origin.x + padding,
            y: labelRect.origin.y + (labelHeight - textSize.height) / 2
        )
        nsText.draw(at: textOrigin, withAttributes: attributes)
    }

    private func drawHintLabel() {
        let text = "Click to capture window  |  ESC to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 10
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding

        let labelRect = CGRect(
            x: bounds.midX - labelWidth / 2,
            y: 30,
            width: labelWidth,
            height: labelHeight
        )
        let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        bgPath.fill()

        let textOrigin = CGPoint(
            x: labelRect.origin.x + padding,
            y: labelRect.origin.y + (labelHeight - textSize.height) / 2
        )
        text.draw(at: textOrigin, withAttributes: attributes)
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = windowAtPoint(point)
        if hit?.id != highlightedWindow?.id {
            highlightedWindow = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let window = windowAtPoint(point) {
            onWindowSelected?(window)
        }
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancelled?()
        }
    }
}
