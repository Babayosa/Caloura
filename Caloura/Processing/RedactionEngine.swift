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
            // Convert normalized Vision coords to pixel coords
            let pixelRect = CGRect(
                x: region.origin.x * width,
                y: region.origin.y * height,
                width: region.width * width,
                height: region.height * height
            )
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
}
