import AppKit
import Foundation

struct ImageProcessor {
    /// Process a captured CGImage into a ProcessedScreenshot
    static func process(
        cgImage: CGImage,
        context: CaptureContext,
        smartCropEnabled: Bool
    ) async -> ProcessedScreenshot {
        var processedImage = cgImage

        // Smart crop if enabled
        if smartCropEnabled {
            processedImage = await SmartCropper.autoCrop(cgImage)
        }

        // Create NSImage
        let nsImage = NSImage(cgImage: processedImage, size: NSSize(
            width: processedImage.width,
            height: processedImage.height
        ))

        return ProcessedScreenshot(
            image: nsImage,
            cgImage: processedImage,
            context: context
        )
    }

    /// Generate PNG data from a CGImage
    static func pngRepresentation(of cgImage: CGImage) -> Data {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Generate JPEG data from a CGImage
    static func jpegRepresentation(of cgImage: CGImage, quality: CGFloat = 0.9) -> Data {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) ?? Data()
    }

    /// Generate TIFF data from a CGImage
    static func tiffRepresentation(of cgImage: CGImage) -> Data {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .tiff, properties: [:]) ?? Data()
    }
}
