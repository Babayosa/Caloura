import AppKit
import ImageIO
import UniformTypeIdentifiers
import os.log

private let imageProcessorLogger = Logger(subsystem: "com.caloura.app", category: "ImageProcessor")

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

    /// Generate HEIC data from a CGImage via CGImageDestination.
    /// Emits a debug log when the source has alpha, so downstream "lost
    /// transparency" reports are traceable to the encoder input rather than
    /// the capture pipeline.
    static func heicRepresentation(of cgImage: CGImage, quality: CGFloat = 0.85) throws -> Data {
        try autoreleasepool {
            switch cgImage.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast:
                break
            default:
                imageProcessorLogger.debug(
                    "heic_encode_with_alpha alpha=\(cgImage.alphaInfo.rawValue, privacy: .public)"
                )
            }

            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.heic.identifier as CFString, 1, nil
            ) else {
                imageProcessorLogger.error("heic_destination_create_failed")
                throw ImageProcessingError.encodingFailed("heic")
            }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                imageProcessorLogger.error("heic_finalize_failed")
                throw ImageProcessingError.encodingFailed("heic")
            }
            return data as Data
        }
    }
}
