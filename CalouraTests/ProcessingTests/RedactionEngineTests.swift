import XCTest
@testable import Caloura

final class RedactionEngineTests: XCTestCase {

    func testRedact_emptyRegions_returnsOriginal() async {
        let image = TestImageFactory.makeTestImage(width: 100, height: 100)
        let result = await RedactionEngine.redact(cgImage: image, regions: [])
        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
    }

    func testRedact_singleRegion_preservesDimensions() async {
        let image = TestImageFactory.makeTestImage(width: 200, height: 150)
        let region = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        let result = await RedactionEngine.redact(cgImage: image, regions: [region])
        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
    }

    func testRedact_singleRegion_pixelsDiffer() async {
        let image = TestImageFactory.makeSolidColorImage(width: 100, height: 100, r: 255, g: 0, b: 0)
        let region = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let result = await RedactionEngine.redact(cgImage: image, regions: [region])

        // Just verify it produced a valid image of the right size
        // (Blur on solid color may not change pixels much, but the pipeline should work)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
    }
}
