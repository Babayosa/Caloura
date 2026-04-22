import CoreGraphics

struct RedactionEngine {
    /// Solid fill color used to overwrite redacted pixels.
    /// 0.15 white = dark gray. Opaque on every channel; no original pixels survive.
    static let fillColor = CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)

    /// Redact regions by overwriting them with an opaque solid fill.
    ///
    /// Pixels under the redaction rectangles are destroyed in the returned image —
    /// no information about the original content is recoverable from the result.
    /// Regions are in normalized Vision coordinates (origin bottom-left, 0-1 range).
    ///
    /// Why solid fill instead of blur: blur is reversible under sufficient compute,
    /// and the persisted image is what callers store on disk + send to clipboard.
    /// See plan/security: pixel-zero redaction.
    static func redact(
        cgImage: CGImage,
        regions: [CGRect]
    ) async -> CGImage {
        guard !regions.isEmpty else { return cgImage }

        return await Task.detached(priority: .userInitiated) {
            performRedaction(cgImage: cgImage, regions: regions)
        }.value
    }

    private static func performRedaction(
        cgImage: CGImage,
        regions: [CGRect]
    ) -> CGImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return cgImage }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return cgImage }

        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgImage, in: imageRect)

        // Union overlapping regions before fill so seams cannot leak between
        // adjacent draws and so we never overdraw a pixel twice.
        let pixelRects = regions
            .map { pixelRect(for: $0, imageWidth: width, imageHeight: height) }
            .filter { !$0.isEmpty }
        let unioned = unionRects(pixelRects)
        guard !unioned.isEmpty else { return cgImage }

        context.setFillColor(fillColor)
        context.fill(unioned)

        return context.makeImage() ?? cgImage
    }

    static func pixelRect(
        for normalizedRegion: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }

        let standardized = normalizedRegion.standardized
        let clampedMinX = max(0, min(1, standardized.minX))
        let clampedMinY = max(0, min(1, standardized.minY))
        let clampedMaxX = max(clampedMinX, min(1, standardized.maxX))
        let clampedMaxY = max(clampedMinY, min(1, standardized.maxY))

        let rect = CGRect(
            x: clampedMinX * imageWidth,
            y: clampedMinY * imageHeight,
            width: (clampedMaxX - clampedMinX) * imageWidth,
            height: (clampedMaxY - clampedMinY) * imageHeight
        )
        guard !rect.isEmpty else { return .zero }

        let padding = max(2, rect.height * 0.01)
        let inflated = rect.insetBy(dx: -padding, dy: -padding)
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        return inflated.intersection(bounds)
    }

    /// Merge overlapping rectangles into a minimal covering set.
    /// Repeated passes until no further merges occur — handles transitive overlap.
    static func unionRects(_ rects: [CGRect]) -> [CGRect] {
        var current = rects.filter { !$0.isEmpty }
        var changed = true
        while changed {
            changed = false
            var merged: [CGRect] = []
            for rect in current {
                if let index = merged.firstIndex(where: { $0.intersects(rect) }) {
                    merged[index] = merged[index].union(rect)
                    changed = true
                } else {
                    merged.append(rect)
                }
            }
            current = merged
        }
        return current
    }
}
