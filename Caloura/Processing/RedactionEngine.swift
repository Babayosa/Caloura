import CoreGraphics
import CoreImage

struct RedactionEngine {
    private static let ciContext = CIContext()

    /// Redact regions by applying Gaussian blur.
    /// Regions are in normalized Vision coordinates (origin bottom-left, 0-1 range).
    static func redact(
        cgImage: CGImage,
        regions: [CGRect],
        blurRadius: CGFloat = 20
    ) async -> CGImage {
        guard !regions.isEmpty else { return cgImage }

        return await Task.detached(priority: .userInitiated) {
            performRedaction(cgImage: cgImage, regions: regions, blurRadius: blurRadius)
        }.value
    }

    private static func performRedaction(
        cgImage: CGImage,
        regions: [CGRect],
        blurRadius: CGFloat
    ) -> CGImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let ciImage = CIImage(cgImage: cgImage)
        let context = ciContext

        // Create fully blurred version
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
            return cgImage
        }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let blurredImage = blurFilter.outputImage else {
            return cgImage
        }

        // Create mask: white rectangles on black background for redaction regions
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let maskContext = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: Int(width) * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return cgImage }

        // Black background (keep original)
        maskContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        maskContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // White regions (apply blur)
        maskContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for region in regions {
            let pixelRect = pixelRect(for: region, imageWidth: width, imageHeight: height)
            guard !pixelRect.isEmpty else { continue }
            maskContext.fill(pixelRect)
        }

        guard let maskCGImage = maskContext.makeImage() else { return cgImage }
        let maskImage = CIImage(cgImage: maskCGImage)

        // Blend: use mask to combine original + blurred
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            return cgImage
        }
        blendFilter.setValue(blurredImage, forKey: kCIInputImageKey)
        blendFilter.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)

        guard let output = blendFilter.outputImage else { return cgImage }

        let renderRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let resultCG = context.createCGImage(output, from: renderRect) else {
            return cgImage
        }

        return resultCG
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
}
