import AppKit

final class WindowSelectionView: NSView {
    var onWindowSelected: ((CaptureWindow) -> Void)?
    var onCancelled: (() -> Void)?

    private let windows: [CaptureWindow]
    private let targetScreen: NSScreen
    private var highlightedWindow: CaptureWindow?

    // Visual styling
    private let overlayColor = NSColor.black.withAlphaComponent(0.45)
    private let highlightBorderColor = NSColor.white
    private let cornerRadius: CGFloat = 10
    private let borderWidth: CGFloat = 2
    private let glowLayers: [(offset: CGFloat, alpha: CGFloat)] = [
        (2, 0.20), (4, 0.12), (6, 0.06)
    ]

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
        // Iterate front-to-back (windows are sorted in z-order by getWindows())
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

            // Darkened overlay with rounded-rect cutout for highlighted window
            let overlayPath = NSBezierPath(rect: bounds)
            let cutout = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            overlayPath.append(cutout.reversed)
            overlayColor.setFill()
            overlayPath.fill()

            // Glow: concentric rounded-rect strokes with decreasing alpha
            for layer in glowLayers {
                let glowRect = rect.insetBy(dx: -layer.offset, dy: -layer.offset)
                let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: cornerRadius + layer.offset, yRadius: cornerRadius + layer.offset)
                glowPath.lineWidth = 2
                NSColor.white.withAlphaComponent(layer.alpha).setStroke()
                glowPath.stroke()
            }

            // White border around highlighted window
            let borderPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            borderPath.lineWidth = borderWidth
            highlightBorderColor.setStroke()
            borderPath.stroke()

            // No fill inside cutout — actual window content shows through

            // Window label with icon + app name + title
            drawWindowLabel(for: highlighted, above: rect)
        } else {
            // No window highlighted — draw uniform overlay
            overlayColor.setFill()
            NSBezierPath(rect: bounds).fill()
        }

        drawHintLabel()
    }

    private func drawWindowLabel(for window: CaptureWindow, above rect: CGRect) {
        let appNameFont = NSFont.systemFont(ofSize: 13, weight: .bold)
        let separatorFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)

        let hasIcon = window.appIcon != nil
        let iconSize: CGFloat = 16
        let iconPadding: CGFloat = hasIcon ? 6 : 0
        let iconWidth: CGFloat = hasIcon ? iconSize + iconPadding : 0

        // Build attributed string: "AppName — Title"
        let attributed = NSMutableAttributedString()

        // App name (bold white)
        if !window.appName.isEmpty {
            attributed.append(NSAttributedString(string: window.appName, attributes: [
                .font: appNameFont,
                .foregroundColor: NSColor.white,
            ]))
        }

        // Separator + title (if we have a title different from app name)
        let displayTitle: String = {
            let t = window.title
            if t.isEmpty || t == window.appName { return "" }
            return String(t.prefix(50))
        }()

        if !displayTitle.isEmpty && !window.appName.isEmpty {
            attributed.append(NSAttributedString(string: " \u{2014} ", attributes: [
                .font: separatorFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ]))
            attributed.append(NSAttributedString(string: displayTitle, attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ]))
        } else if !displayTitle.isEmpty {
            attributed.append(NSAttributedString(string: displayTitle, attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ]))
        }

        let textSize = attributed.size()
        let padding: CGFloat = 10
        let labelWidth = iconWidth + textSize.width + padding * 2
        let labelHeight = textSize.height + padding

        var labelOrigin = CGPoint(
            x: rect.midX - labelWidth / 2,
            y: rect.maxY + 8
        )

        // Clamp to view bounds
        labelOrigin.x = max(4, min(labelOrigin.x, bounds.maxX - labelWidth - 4))
        if labelOrigin.y + labelHeight > bounds.maxY - 4 {
            // Flip below window if near top
            labelOrigin.y = rect.minY - labelHeight - 8
        }

        let labelRect = CGRect(origin: labelOrigin, size: CGSize(width: labelWidth, height: labelHeight))

        // Background pill
        let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.80).setFill()
        bgPath.fill()

        // App icon
        var textX = labelRect.origin.x + padding
        if hasIcon, let icon = window.appIcon {
            let iconY = labelRect.origin.y + (labelHeight - iconSize) / 2
            icon.draw(in: CGRect(x: textX, y: iconY, width: iconSize, height: iconSize))
            textX += iconSize + iconPadding
        }

        // Text
        let textOrigin = CGPoint(
            x: textX,
            y: labelRect.origin.y + (labelHeight - textSize.height) / 2
        )
        attributed.draw(at: textOrigin)
    }

    private func drawHintLabel() {
        let text = "Click to capture  \u{00B7}  ESC to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
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
        NSColor.black.withAlphaComponent(0.55).setFill()
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
