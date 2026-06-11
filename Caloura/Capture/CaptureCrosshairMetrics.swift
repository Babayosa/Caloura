import CoreGraphics

enum CaptureCrosshairMetrics {
    static let armLength: CGFloat = 7
    static let gap: CGFloat = 3
    static let backingPixelWidth: CGFloat = 5
    static let strokePixelWidth: CGFloat = 2

    /// The four crosshair arm rects (left, right, bottom, top) for a
    /// pixel-snapped center point. Shared by the CALayer overlay and the
    /// draw-based selection view so the geometry can never diverge.
    static func segmentFrames(
        at snappedPoint: CGPoint,
        thickness: CGFloat,
        pixel: CGFloat
    ) -> [CGRect] {
        let centered = snap(snappedPoint.x - thickness / 2, pixel: pixel)
        let middle = snap(snappedPoint.y - thickness / 2, pixel: pixel)
        let segmentLength = snap(armLength - gap, pixel: pixel)

        return [
            CGRect(
                x: snap(snappedPoint.x - armLength, pixel: pixel),
                y: middle,
                width: segmentLength,
                height: thickness
            ),
            CGRect(
                x: snap(snappedPoint.x + gap, pixel: pixel),
                y: middle,
                width: segmentLength,
                height: thickness
            ),
            CGRect(
                x: centered,
                y: snap(snappedPoint.y - armLength, pixel: pixel),
                width: thickness,
                height: segmentLength
            ),
            CGRect(
                x: centered,
                y: snap(snappedPoint.y + gap, pixel: pixel),
                width: thickness,
                height: segmentLength
            )
        ]
    }

    static func snap(_ value: CGFloat, pixel: CGFloat) -> CGFloat {
        (value / pixel).rounded() * pixel
    }
}
