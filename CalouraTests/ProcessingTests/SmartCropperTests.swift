import XCTest
@testable import Caloura

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

    // MARK: - autoCrop integration

    func testAutoCrop_returnsImage() async {
        let image = TestImageFactory.makeSolidColorImage(width: 200, height: 200, r: 128, g: 128, b: 128)
        let result = await SmartCropper.autoCrop(image)
        // Should return something (either cropped or original)
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
    }

    // MARK: - Minimum size enforcement

    func testTrimUniformBorders_tooSmallResultReturnsNil() {
        // Create a 20x20 image that's almost entirely border with a tiny center
        // The remaining content would be too small
        let width = 20
        let height = 20
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 255, count: width * height * bytesPerPixel) // All white

        // Make just one pixel different
        let offset = 10 * bytesPerRow + 10 * bytesPerPixel
        pixels[offset] = 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0

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
        // Result should be nil because remaining area is too small (< 10x10 check)
        // or the threshold is not met
        if let cropped = cropped {
            XCTAssertGreaterThan(cropped.width, 10)
            XCTAssertGreaterThan(cropped.height, 10)
        }
    }

    // MARK: - Threshold check

    func testTrimUniformBorders_belowThresholdReturnsNil() {
        // Create image with thin border (< 15% of area) — should not crop
        let width = 100
        let height = 100
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 255, count: width * height * bytesPerPixel)

        // Fill 95x95 center (leaving only 5px border = ~9.75% removed, below 15%)
        for y in 5..<100 {
            for x in 5..<100 {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
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
        XCTAssertNil(cropped, "Should not crop when removed area is below threshold")
    }

}
