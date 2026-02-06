import XCTest
@testable import Caloura

final class ImageProcessorTests: XCTestCase {

    // MARK: - PNG representation

    func testPNGRepresentation_producesValidData() throws {
        let image = TestImageFactory.makeTestImage()
        let data = try ImageProcessor.pngRepresentation(of: image)
        XCTAssertFalse(data.isEmpty, "PNG data should not be empty")
        // PNG magic bytes: 0x89 0x50 0x4E 0x47
        XCTAssertTrue(data.count > 8)
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50) // 'P'
        XCTAssertEqual(data[2], 0x4E) // 'N'
        XCTAssertEqual(data[3], 0x47) // 'G'
    }

    // MARK: - JPEG representation

    func testJPEGRepresentation_producesValidData() throws {
        let image = TestImageFactory.makeTestImage()
        let data = try ImageProcessor.jpegRepresentation(of: image)
        XCTAssertFalse(data.isEmpty, "JPEG data should not be empty")
        // JPEG magic bytes: 0xFF 0xD8
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    // MARK: - TIFF representation

    func testTIFFRepresentation_producesValidData() throws {
        let image = TestImageFactory.makeTestImage()
        let data = try ImageProcessor.tiffRepresentation(of: image)
        XCTAssertFalse(data.isEmpty, "TIFF data should not be empty")
        // TIFF magic bytes: 0x49 0x49 (little-endian) or 0x4D 0x4D (big-endian)
        let firstByte = data[0]
        XCTAssertTrue(firstByte == 0x49 || firstByte == 0x4D, "Should start with TIFF magic bytes")
    }

    // MARK: - process() returns correct dimensions

    func testProcess_returnsCorrectDimensions() async {
        let image = TestImageFactory.makeTestImage(width: 200, height: 150)
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
