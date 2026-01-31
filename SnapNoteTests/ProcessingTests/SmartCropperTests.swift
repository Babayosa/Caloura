import XCTest
@testable import SnapNote

final class SmartCropperTests: XCTestCase {

    func testTrimUniformBorders_whiteBorder() throws {
        // Create a 100x100 image with white border and colored center
        let width = 100
        let height = 100
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 255, count: width * height * bytesPerPixel) // All white

        // Fill center 60x60 with blue
        for y in 20..<80 {
            for x in 20..<80 {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = 0       // R
                pixels[offset + 1] = 0   // G
                pixels[offset + 2] = 255 // B
                pixels[offset + 3] = 255 // A
            }
        }

        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let cropped = SmartCropper.trimUniformBorders(cgImage)

        // Should have cropped the white borders
        XCTAssertNotNil(cropped, "Should have trimmed borders")
        if let cropped = cropped {
            XCTAssertLessThan(cropped.width, width, "Width should be smaller after crop")
            XCTAssertLessThan(cropped.height, height, "Height should be smaller after crop")
        }
    }

    func testTrimUniformBorders_noBorder() throws {
        // Create a 50x50 image with no uniform border
        let width = 50
        let height = 50
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        // Fill with random-ish colors (alternating)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = UInt8((x * 5) % 256)     // R
                pixels[offset + 1] = UInt8((y * 5) % 256) // G
                pixels[offset + 2] = 128                    // B
                pixels[offset + 3] = 255                    // A
            }
        }

        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let cropped = SmartCropper.trimUniformBorders(cgImage)

        // Should not have cropped (no uniform border)
        XCTAssertNil(cropped, "Should not crop when there's no uniform border")
    }
}
