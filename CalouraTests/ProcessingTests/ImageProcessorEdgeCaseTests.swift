import XCTest
@testable import Caloura

final class ImageProcessorEdgeCaseTests: XCTestCase {

    // MARK: - 1x1 pixel image through process() with smartCrop

    func testProcess_1x1Image_smartCropEnabled_doesNotCrash() async {
        let image = TestImageFactory.makeTestImage(width: 1, height: 1)
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
        let image = TestImageFactory.makeTestImage(width: 1, height: 1)
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
        let image = TestImageFactory.makeTestImage(width: 1, height: 1)
        let cropped = SmartCropper.trimUniformBorders(image)
        // 1x1 is too small (below 10x10 minimum) and has no border
        // to trim, so it should return nil
        XCTAssertNil(cropped)
    }

    // MARK: - Very large image PNG representation

    func testPNGRepresentation_largeImage_producesValidPNG() throws {
        let image = TestImageFactory.makeTestImage(width: 4000, height: 3000)
        let data = try ImageProcessor.pngRepresentation(of: image)

        XCTAssertFalse(data.isEmpty, "PNG data should not be empty")
        XCTAssertTrue(data.count > 8)
        // Verify PNG magic bytes
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50) // 'P'
        XCTAssertEqual(data[2], 0x4E) // 'N'
        XCTAssertEqual(data[3], 0x47) // 'G'
    }

    func testProcess_largeImage_returnsCorrectDimensions() async {
        let image = TestImageFactory.makeTestImage(width: 4000, height: 3000)
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
        let image = TestImageFactory.makeSolidColorImage(
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
        let image = TestImageFactory.makeSolidColorImage(
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
        let image = TestImageFactory.makeSolidColorImage(
            width: 100, height: 100,
            r: 0, g: 0, b: 0
        )
        let cropped = SmartCropper.trimUniformBorders(image)
        XCTAssertNil(
            cropped,
            "Solid black image should return nil"
        )
    }

}
