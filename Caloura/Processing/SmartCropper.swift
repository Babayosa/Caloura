import AppKit
import os.log
import Vision

private struct BorderInsets {
    let top: Int
    let bottom: Int
    let left: Int
    let right: Int
}

private struct NormalizedBitmap {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]
}

struct SmartCropper {
    /// Minimum percentage of area that must be removed for crop to apply
    private static let minCropThreshold: CGFloat = 0.15
    /// Padding factor around salient region
    private static let paddingFactor: CGFloat = 0.05
    /// Maximum time to wait for Vision processing before falling back
    private static let visionTimeout: UInt64 = 300_000_000 // 300ms
    private static let logger = Logger(
        subsystem: "com.caloura.app",
        category: "SmartCropper"
    )

    /// Auto-crop using Vision saliency analysis.
    /// Runs entirely off the main thread for performance.
    static func autoCrop(_ cgImage: CGImage) async -> CGImage {
        do {
            // Run Vision processing on background thread with timeout
            let saliencyResult = try await withTimeout(
                seconds: Double(visionTimeout) / 1_000_000_000
            ) {
                try await saliencyCrop(cgImage)
            }

            if let cropped = saliencyResult {
                return cropped
            }
        } catch TimeoutError.timedOut {
            logger.debug("Vision saliency crop timed out; using border-trim fallback")
        } catch {
            logger.debug("Vision saliency crop failed: \(error.localizedDescription)")
        }

        // Fallback: trim uniform borders (fast, CPU-based)
        let borderTrimmed = await Task.detached(priority: .userInitiated) {
            return trimUniformBorders(cgImage)
        }.value

        if let cropped = borderTrimmed {
            return cropped
        }

        return cgImage
    }

    // MARK: - Saliency Crop (runs on background thread)

    private static func saliencyCrop(_ cgImage: CGImage) async throws -> CGImage? {
        // Offload Vision work to background thread
        return try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            guard let results = request.results, !results.isEmpty else {
                return nil
            }

            // Union all salient object bounding boxes
            var unionRect = CGRect.null
            for observation in results {
                for salientObject in observation.salientObjects ?? [] {
                    unionRect = unionRect.union(salientObject.boundingBox)
                }
            }

            guard !unionRect.isNull else { return nil }

            // Add padding
            let paddingX = unionRect.width * paddingFactor
            let paddingY = unionRect.height * paddingFactor
            let paddedRect = unionRect.insetBy(dx: -paddingX, dy: -paddingY)

            // Clamp to image bounds (normalized 0..1 coordinates)
            let clampedRect = paddedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

            // Convert normalized coordinates to pixel coordinates
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)
            let pixelRect = CGRect(
                x: clampedRect.origin.x * imageWidth,
                y: (1.0 - clampedRect.origin.y - clampedRect.height) * imageHeight,
                width: clampedRect.width * imageWidth,
                height: clampedRect.height * imageHeight
            ).integral

            // Check if crop removes enough area
            let originalArea = imageWidth * imageHeight
            let croppedArea = pixelRect.width * pixelRect.height
            let removedRatio = 1.0 - (croppedArea / originalArea)

            guard removedRatio >= minCropThreshold else {
                return nil
            }

            return cgImage.cropping(to: pixelRect)
        }.value
    }

    // MARK: - Border Trim Fallback

    /// Trims uniform-color borders (e.g., whitespace around slides)
    static func trimUniformBorders(_ cgImage: CGImage) -> CGImage? {
        guard let bitmap = normalizedBitmap(for: cgImage) else {
            return nil
        }

        // Get the corner pixel color as reference
        let refR = bitmap.bytes[0]
        let refG = bitmap.bytes[1]
        let refB = bitmap.bytes[2]

        let tolerance: UInt8 = 10

        @inline(__always)
        func pixelMatchesRef(x: Int, y: Int) -> Bool {
            let offset = y * bitmap.bytesPerRow + x * 4
            return abs(Int(bitmap.bytes[offset]) - Int(refR)) <= Int(tolerance) &&
                   abs(Int(bitmap.bytes[offset + 1]) - Int(refG)) <= Int(tolerance) &&
                   abs(Int(bitmap.bytes[offset + 2]) - Int(refB)) <= Int(tolerance)
        }

        let borders = scanBorders(
            width: bitmap.width, height: bitmap.height,
            pixelMatchesRef: pixelMatchesRef
        )

        let cropRect = CGRect(
            x: borders.left, y: borders.top,
            width: borders.right - borders.left,
            height: borders.bottom - borders.top
        )

        // Check threshold
        let originalArea = CGFloat(bitmap.width * bitmap.height)
        let croppedArea = cropRect.width * cropRect.height
        let removedRatio = 1.0 - (croppedArea / originalArea)

        guard removedRatio >= minCropThreshold,
              cropRect.width > 10 && cropRect.height > 10 else {
            return nil
        }

        return cgImage.cropping(to: cropRect)
    }

    private static func normalizedBitmap(for cgImage: CGImage) -> NormalizedBitmap? {
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let rendered = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else { return nil }
        return NormalizedBitmap(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )
    }

    private static func scanBorders(
        width: Int, height: Int,
        pixelMatchesRef: (Int, Int) -> Bool
    ) -> BorderInsets {
        // Use larger stride for faster scanning (8 pixels instead of 4)
        let stride = 8

        // Find top border
        var top = 0
        outer_top: for y in 0..<height {
            for x in Swift.stride(from: 0, to: width, by: stride)
                where !pixelMatchesRef(x, y) {
                break outer_top
            }
            top = y + 1
        }

        // Find bottom border
        var bottom = height
        outer_bottom: for y in Swift.stride(from: height - 1, through: 0, by: -1) {
            for x in Swift.stride(from: 0, to: width, by: stride)
                where !pixelMatchesRef(x, y) {
                break outer_bottom
            }
            bottom = y
        }

        // Find left border
        var left = 0
        outer_left: for x in 0..<width {
            for y in Swift.stride(from: top, to: bottom, by: stride)
                where !pixelMatchesRef(x, y) {
                break outer_left
            }
            left = x + 1
        }

        // Find right border
        var right = width
        outer_right: for x in Swift.stride(from: width - 1, through: 0, by: -1) {
            for y in Swift.stride(from: top, to: bottom, by: stride)
                where !pixelMatchesRef(x, y) {
                break outer_right
            }
            right = x
        }

        return BorderInsets(top: top, bottom: bottom, left: left, right: right)
    }
}
