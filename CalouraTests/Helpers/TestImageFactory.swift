import CoreGraphics
import Foundation

/// Shared test helpers for creating CGImage instances.
/// Used across ImageProcessorTests, SmartCropperTests, OCREngineTests, etc.
enum TestImageFactory {

    /// Creates a CGImage filled with a default purple color (r:0.5, g:0.3, b:0.8).
    static func makeTestImage(
        width: Int = 100,
        height: Int = 100
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        context.setFillColor(
            red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0
        )
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()!
    }

    /// Creates a CGImage filled with the specified CGColor.
    static func makeTestImage(
        width: Int,
        height: Int,
        color: CGColor
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        context.setFillColor(color)
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()!
    }

    /// Creates a CGImage with exact per-pixel RGB values via CGDataProvider.
    /// Useful when pixel-exact color values matter (e.g., border trimming tests).
    static func makeSolidColorImage(
        width: Int,
        height: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: width * height * bytesPerPixel
        )
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
