import AppKit

enum ImageProcessingError: LocalizedError {
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let format):
            return "Failed to encode image as \(format)"
        }
    }
}

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
        let nsImage = NSImage(cgImage: processedImage, size: .zero)

        return ProcessedScreenshot(
            image: nsImage,
            cgImage: processedImage,
            context: context
        )
    }

    /// Generate PNG data from a CGImage
    static func pngRepresentation(of cgImage: CGImage) throws -> Data {
        try autoreleasepool {
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
                throw ImageProcessingError.encodingFailed("png")
            }
            return data
        }
    }

    /// Generate JPEG data from a CGImage
    static func jpegRepresentation(of cgImage: CGImage, quality: CGFloat = 0.9) throws -> Data {
        try autoreleasepool {
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                throw ImageProcessingError.encodingFailed("jpeg")
            }
            return data
        }
    }

    /// Generate TIFF data from a CGImage
    static func tiffRepresentation(of cgImage: CGImage) throws -> Data {
        try autoreleasepool {
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmapRep.representation(using: .tiff, properties: [:]) else {
                throw ImageProcessingError.encodingFailed("tiff")
            }
            return data
        }
    }
}
