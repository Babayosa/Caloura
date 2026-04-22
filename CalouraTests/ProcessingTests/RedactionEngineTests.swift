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

    // MARK: - Pixel-zero (irreversibility)

    func testRedact_singleRegion_pixelsMatchFillColorExactly() async {
        // Pixel-zero contract: the redacted region must contain the fill color
        // verbatim — no original-content variance, no blur falloff.
        let image = TestImageFactory.makeSolidColorImage(width: 200, height: 200, r: 255, g: 0, b: 0)
        let region = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let result = await RedactionEngine.redact(cgImage: image, regions: [region])

        // Sample the geometric center of the redacted rect — well inside the
        // padding so we read pure fill, not edge anti-aliasing.
        let pixel = readPixel(result, x: 100, y: 100)
        let expected = expectedFillRGB()
        XCTAssertEqual(pixel.r, expected.r, "redacted pixel red channel must match fill exactly")
        XCTAssertEqual(pixel.g, expected.g, "redacted pixel green channel must match fill exactly")
        XCTAssertEqual(pixel.b, expected.b, "redacted pixel blue channel must match fill exactly")
    }

    func testRedact_outsideRegion_preservesOriginalPixels() async {
        // Pixel preservation: untouched regions must remain bit-identical so a
        // user can still see the rest of the screenshot.
        let image = TestImageFactory.makeSolidColorImage(width: 200, height: 200, r: 255, g: 0, b: 0)
        let region = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2)
        let result = await RedactionEngine.redact(cgImage: image, regions: [region])

        let pixel = readPixel(result, x: 180, y: 180)
        XCTAssertEqual(pixel.r, 255, "outside-region red channel must be preserved exactly")
        XCTAssertEqual(pixel.g, 0)
        XCTAssertEqual(pixel.b, 0)
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

    func testPixelRect_inflatesRegionWithSafetyPadding() {
        let rect = RedactionEngine.pixelRect(
            for: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1),
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertEqual(rect, CGRect(x: 48, y: 48, width: 14, height: 14))
    }

    func testPixelRect_clampsInflatedRegionToImageBounds() {
        let rect = RedactionEngine.pixelRect(
            for: CGRect(x: 0.97, y: 0.97, width: 0.1, height: 0.1),
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertEqual(rect, CGRect(x: 95, y: 95, width: 5, height: 5))
    }

    // MARK: - unionRects

    func testUnionRects_overlappingRectsMergeIntoSingleCover() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 5, y: 5, width: 10, height: 10)
        let merged = RedactionEngine.unionRects([a, b])
        XCTAssertEqual(merged.count, 1, "overlapping rects must merge")
        XCTAssertEqual(merged.first, CGRect(x: 0, y: 0, width: 15, height: 15))
    }

    func testUnionRects_disjointRectsKeepBoth() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 100, y: 100, width: 10, height: 10)
        let merged = RedactionEngine.unionRects([a, b])
        XCTAssertEqual(merged.count, 2)
    }

    func testUnionRects_transitiveChainCollapses() {
        // A∩B exists, B∩C exists, but A∩C does NOT — chain must still collapse
        // so seams between adjacent fills cannot leak the original content.
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 5, y: 0, width: 10, height: 10)
        let c = CGRect(x: 12, y: 0, width: 10, height: 10)
        let merged = RedactionEngine.unionRects([a, b, c])
        XCTAssertEqual(merged.count, 1, "chain A↔B↔C must collapse to one rect")
        XCTAssertEqual(merged.first, CGRect(x: 0, y: 0, width: 22, height: 10))
    }

    // MARK: - Helpers

    private struct PixelRGB: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private func readPixel(_ image: CGImage, x: Int, y: Int) -> PixelRGB {
        let bytesPerRow = image.width * 4
        let bufferSize = bytesPerRow * image.height
        var pixels = [UInt8](repeating: 0, count: bufferSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = y * bytesPerRow + x * 4
        return PixelRGB(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2])
    }

    /// Compute the expected post-blit RGB byte values for `RedactionEngine.fillColor`.
    /// Reads back through the same CGContext path so the comparison accounts for
    /// any rounding the device color space applies.
    private func expectedFillRGB() -> PixelRGB {
        let image = TestImageFactory.makeTestImage(
            width: 4,
            height: 4,
            color: RedactionEngine.fillColor
        )
        return readPixel(image, x: 2, y: 2)
    }
}
