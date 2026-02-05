import AppKit
import Vision

private struct BorderInsets {
    let top: Int
    let bottom: Int
    let left: Int
    let right: Int
}

struct SmartCropper {
    /// Minimum percentage of area that must be removed for crop to apply
    private static let minCropThreshold: CGFloat = 0.15
    /// Padding factor around salient region
    private static let paddingFactor: CGFloat = 0.05
    /// Maximum time to wait for Vision processing before falling back
    private static let visionTimeout: UInt64 = 300_000_000 // 300ms

    /// Auto-crop using Vision saliency analysis.
    /// Runs entirely off the main thread for performance.
    static func autoCrop(_ cgImage: CGImage) async -> CGImage {
        // Run Vision processing on background thread with timeout
        let saliencyResult = await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                try? await saliencyCrop(cgImage)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: visionTimeout)
                return nil // Timeout sentinel
            }

            // Return first non-nil result, or nil if timeout wins
            for await result in group where result != nil {
                group.cancelAll()
                return result
            }
            return nil
        }

        if let cropped = saliencyResult {
            return cropped
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
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let pointer = CFDataGetBytePtr(data) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        guard bytesPerPixel >= 3 else { return nil }

        // Get the corner pixel color as reference
        let refR = pointer[0]
        let refG = pointer[1]
        let refB = pointer[2]

        let tolerance: UInt8 = 10

        @inline(__always)
        func pixelMatchesRef(x: Int, y: Int) -> Bool {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return abs(Int(pointer[offset]) - Int(refR)) <= Int(tolerance) &&
                   abs(Int(pointer[offset + 1]) - Int(refG)) <= Int(tolerance) &&
                   abs(Int(pointer[offset + 2]) - Int(refB)) <= Int(tolerance)
        }

        let borders = scanBorders(
            width: width, height: height,
            pixelMatchesRef: pixelMatchesRef
        )

        let cropRect = CGRect(
            x: borders.left, y: borders.top,
            width: borders.right - borders.left,
            height: borders.bottom - borders.top
        )

        // Check threshold
        let originalArea = CGFloat(width * height)
        let croppedArea = cropRect.width * cropRect.height
        let removedRatio = 1.0 - (croppedArea / originalArea)

        guard removedRatio >= minCropThreshold,
              cropRect.width > 10 && cropRect.height > 10 else {
            return nil
        }

        return cgImage.cropping(to: cropRect)
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
