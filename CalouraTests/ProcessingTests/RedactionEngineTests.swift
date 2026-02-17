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
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
    }

    // MARK: - Edge cases

    func testRedact_overlappingRegions_preservesDimensions() async {
        let image = TestImageFactory.makeTestImage(width: 200, height: 200)
        let regions = [
            CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            CGRect(x: 0.3, y: 0.3, width: 0.5, height: 0.5)
        ]
        let result = await RedactionEngine.redact(cgImage: image, regions: regions)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 200)
    }

    func testRedact_regionBeyondBounds_doesNotCrash() async {
        let image = TestImageFactory.makeTestImage(width: 100, height: 100)
        let region = CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5)
        let result = await RedactionEngine.redact(cgImage: image, regions: [region])
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
    }

    func testRedact_tinyImage_preservesDimensions() async {
        let image = TestImageFactory.makeTestImage(width: 1, height: 1)
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        let result = await RedactionEngine.redact(cgImage: image, regions: [region])
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    func testRedact_fullImageRegion_preservesDimensions() async {
        let image = TestImageFactory.makeTestImage(width: 100, height: 100)
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        let result = await RedactionEngine.redact(cgImage: image, regions: [region])
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
    }

    func testRedact_manyRegions_preservesDimensions() async {
        let image = TestImageFactory.makeTestImage(width: 200, height: 200)
        let regions = (0..<10).map { i in
            CGRect(x: Double(i) * 0.1, y: 0.1, width: 0.08, height: 0.08)
        }
        let result = await RedactionEngine.redact(cgImage: image, regions: regions)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 200)
    }
}
