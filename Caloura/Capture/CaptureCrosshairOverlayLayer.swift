import AppKit
import QuartzCore

@MainActor
final class CaptureCrosshairOverlayLayer {
    private let backingLayer = CALayer()
    private let strokeLayer = CALayer()
    private let backingSegments: [CALayer]
    private let strokeSegments: [CALayer]
    private var currentPoint: CGPoint?

    init() {
        backingSegments = Self.makeSegments(color: NSColor.black.withAlphaComponent(0.8))
        strokeSegments = Self.makeSegments(color: .white)
        configureContainer(backingLayer)
        configureContainer(strokeLayer)
        backingSegments.forEach(backingLayer.addSublayer)
        strokeSegments.forEach(strokeLayer.addSublayer)
        backingLayer.isHidden = true
        strokeLayer.isHidden = true
    }

    func add(to rootLayer: CALayer) {
        rootLayer.addSublayer(backingLayer)
        rootLayer.addSublayer(strokeLayer)
    }

    func updateBounds(_ bounds: CGRect, scale: CGFloat) {
        backingLayer.frame = bounds
        strokeLayer.frame = bounds
        setContentsScale(scale)
        if let currentPoint {
            update(to: currentPoint, in: bounds)
        }
    }

    func update(to point: CGPoint, in bounds: CGRect) {
        currentPoint = point
        let visible = bounds.contains(point)
        backingLayer.isHidden = !visible
        strokeLayer.isHidden = !visible
        guard visible else { return }

        let scale = max(strokeLayer.contentsScale, 1)
        let pixel = 1 / scale
        let snappedPoint = snap(point, scale: scale)
        layoutSegments(
            backingSegments,
            at: snappedPoint,
            thickness: pixel * CaptureCrosshairMetrics.backingPixelWidth,
            pixel: pixel
        )
        layoutSegments(
            strokeSegments,
            at: snappedPoint,
            thickness: pixel * CaptureCrosshairMetrics.strokePixelWidth,
            pixel: pixel
        )
    }

    func hide() {
        currentPoint = nil
        backingLayer.isHidden = true
        strokeLayer.isHidden = true
    }

    private func configureContainer(_ layer: CALayer) {
        layer.masksToBounds = false
        layer.actions = [
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull()
        ]
    }

    private static func makeSegments(color: NSColor) -> [CALayer] {
        (0..<4).map { _ in
            let layer = CALayer()
            layer.backgroundColor = color.cgColor
            layer.anchorPoint = .zero
            layer.actions = [
                "backgroundColor": NSNull(),
                "bounds": NSNull(),
                "frame": NSNull(),
                "hidden": NSNull(),
                "position": NSNull()
            ]
            return layer
        }
    }

    private func setContentsScale(_ scale: CGFloat) {
        let layers = [backingLayer, strokeLayer] + backingSegments + strokeSegments
        layers.forEach { $0.contentsScale = scale }
    }

    private func layoutSegments(_ segments: [CALayer], at point: CGPoint, thickness: CGFloat, pixel: CGFloat) {
        let armLength = CaptureCrosshairMetrics.armLength
        let gap = CaptureCrosshairMetrics.gap
        let centered = snap(point.x - thickness / 2, pixel: pixel)
        let middle = snap(point.y - thickness / 2, pixel: pixel)

        segments[0].frame = CGRect(
            x: snap(point.x - armLength, pixel: pixel),
            y: middle,
            width: snap(armLength - gap, pixel: pixel),
            height: thickness
        )
        segments[1].frame = CGRect(
            x: snap(point.x + gap, pixel: pixel),
            y: middle,
            width: snap(armLength - gap, pixel: pixel),
            height: thickness
        )
        segments[2].frame = CGRect(
            x: centered,
            y: snap(point.y - armLength, pixel: pixel),
            width: thickness,
            height: snap(armLength - gap, pixel: pixel)
        )
        segments[3].frame = CGRect(
            x: centered,
            y: snap(point.y + gap, pixel: pixel),
            width: thickness,
            height: snap(armLength - gap, pixel: pixel)
        )
    }

    private func snap(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(
            x: snap(point.x, pixel: 1 / scale),
            y: snap(point.y, pixel: 1 / scale)
        )
    }

    private func snap(_ value: CGFloat, pixel: CGFloat) -> CGFloat {
        (value / pixel).rounded() * pixel
    }
}
