import XCTest
@testable import Caloura

final class ImageProcessorEdgeCaseTests: XCTestCase {

    // MARK: - 1x1 pixel image through process() with smartCrop

    func testProcess_1x1Image_smartCropEnabled_doesNotCrash() async {
        let image = makeTestImage(width: 1, height: 1)
        let context = CaptureContext(
            mode: .area, sourceAppName: "Test"
        )
        let processed = await ImageProcessor.process(
            cgImage: image,
            context: context,
            smartCropEnabled: true
        )
        // Should return a valid result without crashing
        XCTAssertGreaterThan(processed.width, 0)
        XCTAssertGreaterThan(processed.height, 0)
    }

    func testProcess_1x1Image_smartCropDisabled() async {
        let image = makeTestImage(width: 1, height: 1)
        let context = CaptureContext(
            mode: .area, sourceAppName: "Test"
        )
        let processed = await ImageProcessor.process(
            cgImage: image,
            context: context,
            smartCropEnabled: false
        )
        XCTAssertEqual(processed.width, 1)
        XCTAssertEqual(processed.height, 1)
    }

    // MARK: - 1x1 through SmartCropper.trimUniformBorders

    func testTrimUniformBorders_1x1_returnsNil() {
        let image = makeTestImage(width: 1, height: 1)
        let cropped = SmartCropper.trimUniformBorders(image)
        // 1x1 is too small (below 10x10 minimum) and has no border
        // to trim, so it should return nil
        XCTAssertNil(cropped)
    }

    // MARK: - Very large image PNG representation

    func testPNGRepresentation_largeImage_producesValidPNG() {
        let image = makeTestImage(width: 4000, height: 3000)
        let data = ImageProcessor.pngRepresentation(of: image)

        XCTAssertFalse(data.isEmpty, "PNG data should not be empty")
        XCTAssertTrue(data.count > 8)
        // Verify PNG magic bytes
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50) // 'P'
        XCTAssertEqual(data[2], 0x4E) // 'N'
        XCTAssertEqual(data[3], 0x47) // 'G'
    }

    func testProcess_largeImage_returnsCorrectDimensions() async {
        let image = makeTestImage(width: 4000, height: 3000)
        let context = CaptureContext(
            mode: .fullscreen, sourceAppName: "Test"
        )
        let processed = await ImageProcessor.process(
            cgImage: image,
            context: context,
            smartCropEnabled: false
        )
        XCTAssertEqual(processed.width, 4000)
        XCTAssertEqual(processed.height, 3000)
    }

    // MARK: - Solid-color image through trimUniformBorders

    func testTrimUniformBorders_solidColor_returnsNil() {
        // A completely uniform image has no content region distinct
        // from borders, so trimming should return nil.
        let image = makeSolidColorImage(
            width: 200, height: 200,
            r: 128, g: 128, b: 128
        )
        let cropped = SmartCropper.trimUniformBorders(image)
        XCTAssertNil(
            cropped,
            "Solid-color image should return nil (all borders uniform)"
        )
    }

    func testTrimUniformBorders_solidWhite_returnsNil() {
        let image = makeSolidColorImage(
            width: 100, height: 100,
            r: 255, g: 255, b: 255
        )
        let cropped = SmartCropper.trimUniformBorders(image)
        XCTAssertNil(
            cropped,
            "Solid white image should return nil"
        )
    }

    func testTrimUniformBorders_solidBlack_returnsNil() {
        let image = makeSolidColorImage(
            width: 100, height: 100,
            r: 0, g: 0, b: 0
        )
        let cropped = SmartCropper.trimUniformBorders(image)
        XCTAssertNil(
            cropped,
            "Solid black image should return nil"
        )
    }

    // MARK: - Helpers

    private func makeTestImage(
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

    private func makeSolidColorImage(
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
