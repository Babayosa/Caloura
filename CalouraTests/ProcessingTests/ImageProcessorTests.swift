import XCTest
@testable import Caloura

final class ImageProcessorTests: XCTestCase {

    private func makeTestImage(width: Int = 100, height: Int = 100) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        // Fill with a color so the image data is non-empty
        context.setFillColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - PNG representation

    func testPNGRepresentation_producesValidData() {
        let image = makeTestImage()
        let data = ImageProcessor.pngRepresentation(of: image)
        XCTAssertFalse(data.isEmpty, "PNG data should not be empty")
        // PNG magic bytes: 0x89 0x50 0x4E 0x47
        XCTAssertTrue(data.count > 8)
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50) // 'P'
        XCTAssertEqual(data[2], 0x4E) // 'N'
        XCTAssertEqual(data[3], 0x47) // 'G'
    }

    // MARK: - JPEG representation

    func testJPEGRepresentation_producesValidData() {
        let image = makeTestImage()
        let data = ImageProcessor.jpegRepresentation(of: image)
        XCTAssertFalse(data.isEmpty, "JPEG data should not be empty")
        // JPEG magic bytes: 0xFF 0xD8
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    // MARK: - TIFF representation

    func testTIFFRepresentation_producesValidData() {
        let image = makeTestImage()
        let data = ImageProcessor.tiffRepresentation(of: image)
        XCTAssertFalse(data.isEmpty, "TIFF data should not be empty")
        // TIFF magic bytes: 0x49 0x49 (little-endian) or 0x4D 0x4D (big-endian)
        let firstByte = data[0]
        XCTAssertTrue(firstByte == 0x49 || firstByte == 0x4D, "Should start with TIFF magic bytes")
    }

    // MARK: - process() returns correct dimensions

    func testProcess_returnsCorrectDimensions() async {
        let image = makeTestImage(width: 200, height: 150)
        let context = CaptureContext(mode: .area, sourceAppName: "Test")
        let processed = await ImageProcessor.process(
            cgImage: image,
            context: context,
            smartCropEnabled: false
        )
        XCTAssertEqual(processed.width, 200)
        XCTAssertEqual(processed.height, 150)
    }
}
