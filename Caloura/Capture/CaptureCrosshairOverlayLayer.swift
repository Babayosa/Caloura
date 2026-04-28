import AppKit
import QuartzCore

@MainActor
final class CaptureCrosshairOverlayLayer {
    private let shadowLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private var currentPoint: CGPoint?

    init() {
        configure(layer: shadowLayer, color: NSColor.black.withAlphaComponent(0.75), lineWidth: 3)
        configure(layer: strokeLayer, color: .white, lineWidth: 1.25)
        shadowLayer.isHidden = true
        strokeLayer.isHidden = true
    }

    func add(to rootLayer: CALayer) {
        rootLayer.addSublayer(shadowLayer)
        rootLayer.addSublayer(strokeLayer)
    }

    func updateBounds(_ bounds: CGRect, scale: CGFloat) {
        shadowLayer.frame = bounds
        strokeLayer.frame = bounds
        shadowLayer.contentsScale = scale
        strokeLayer.contentsScale = scale
        if let currentPoint {
            update(to: currentPoint, in: bounds)
        }
    }

    func update(to point: CGPoint, in bounds: CGRect) {
        currentPoint = point
        let visible = bounds.contains(point)
        shadowLayer.isHidden = !visible
        strokeLayer.isHidden = !visible
        guard visible else { return }

        let path = CGMutablePath()
        let armLength: CGFloat = 13
        let gap: CGFloat = 4
        path.move(to: CGPoint(x: point.x - armLength, y: point.y))
        path.addLine(to: CGPoint(x: point.x - gap, y: point.y))
        path.move(to: CGPoint(x: point.x + gap, y: point.y))
        path.addLine(to: CGPoint(x: point.x + armLength, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - armLength))
        path.addLine(to: CGPoint(x: point.x, y: point.y - gap))
        path.move(to: CGPoint(x: point.x, y: point.y + gap))
        path.addLine(to: CGPoint(x: point.x, y: point.y + armLength))

        shadowLayer.path = path
        strokeLayer.path = path
    }

    func hide() {
        currentPoint = nil
        shadowLayer.isHidden = true
        strokeLayer.isHidden = true
    }

    private func configure(layer: CAShapeLayer, color: NSColor, lineWidth: CGFloat) {
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.actions = [
            "path": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
    }
}
