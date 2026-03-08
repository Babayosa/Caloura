import CoreGraphics

extension ScrollCaptureHelpers {
    static func pixelAlignedRect(
        _ rect: CGRect,
        scale: CGFloat,
        within bounds: CGRect
    ) -> CGRect {
        let clamped = rect.intersection(bounds)
        guard !clamped.isNull else { return .zero }

        let minX = floor(clamped.minX * scale) / scale
        let minY = floor(clamped.minY * scale) / scale
        let maxX = ceil(clamped.maxX * scale) / scale
        let maxY = ceil(clamped.maxY * scale) / scale

        let aligned = CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )

        return aligned.intersection(bounds)
    }
}
