import XCTest
@testable import Caloura

final class BeautifierTests: XCTestCase {

    func testBeautify_addsPadding_increasesSize() async {
        let image = TestImageFactory.makeTestImage(width: 100, height: 80)
        let theme = BeautifyTheme.builtInThemes.first(where: { $0.name == "Clean" })!
        let result = await Beautifier.beautify(cgImage: image, theme: theme)

        let expectedWidth = 100 + Int(theme.padding * 2)
        let expectedHeight = 80 + Int(theme.padding * 2)
        XCTAssertEqual(result.width, expectedWidth)
        XCTAssertEqual(result.height, expectedHeight)
    }

    func testBeautify_zeroPadding_sameSize() async {
        let image = TestImageFactory.makeTestImage(width: 200, height: 150)
        var theme = BeautifyTheme.builtInThemes[0]
        theme.padding = 0
        let result = await Beautifier.beautify(cgImage: image, theme: theme)

        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 150)
    }

    func testBeautify_preservesContent() async {
        // Use a solid red image, check center pixel after beautification
        let image = TestImageFactory.makeSolidColorImage(width: 100, height: 100, r: 255, g: 0, b: 0)
        var theme = BeautifyTheme.builtInThemes[0]
        theme.padding = 20
        theme.cornerRadius = 0
        theme.shadowRadius = 0
        theme.shadowOpacity = 0
        let result = await Beautifier.beautify(cgImage: image, theme: theme)

        // Center of the result should be in the content area
        let centerX = result.width / 2
        let centerY = result.height / 2
        let pixel = getPixel(from: result, x: centerX, y: centerY)
        // Red channel should be high (content preserved)
        XCTAssertGreaterThan(pixel.r, 200, "Center pixel should be red (content preserved)")
    }

    func testBeautify_shadowPresent() async {
        let image = TestImageFactory.makeSolidColorImage(width: 50, height: 50, r: 255, g: 255, b: 255)
        let baseTheme = BeautifyTheme.builtInThemes.first(where: { $0.name == "Clean" })!

        // Render with shadow
        var withShadow = baseTheme
        withShadow.shadowOpacity = 0.5
        withShadow.shadowRadius = 20
        withShadow.shadowOffset = CGSize(width: 0, height: 4)
        let resultWithShadow = await Beautifier.beautify(cgImage: image, theme: withShadow)

        // Render without shadow
        var noShadow = baseTheme
        noShadow.shadowOpacity = 0
        noShadow.shadowRadius = 0
        noShadow.shadowOffset = .zero
        let resultNoShadow = await Beautifier.beautify(cgImage: image, theme: noShadow)

        // Check a pixel just below the content area where the shadow offset points.
        // In CG coordinates (origin bottom-left), shadowOffset.height=4 with negation means
        // the shadow falls downward in screen coords (lower y in CG).
        // Content rect starts at y=padding. A pixel just below that (lower y) is in the shadow zone.
        let probeX = resultWithShadow.width / 2
        let probeY = Int(baseTheme.padding) - 5 // just below content rect in CG coords

        let pixelWithShadow = getPixel(from: resultWithShadow, x: probeX, y: probeY)
        let pixelNoShadow = getPixel(from: resultNoShadow, x: probeX, y: probeY)

        // The shadow should make this pixel darker (lower RGB values) than without shadow
        let brightnessWithShadow = Int(pixelWithShadow.r) + Int(pixelWithShadow.g) + Int(pixelWithShadow.b)
        let brightnessNoShadow = Int(pixelNoShadow.r) + Int(pixelNoShadow.g) + Int(pixelNoShadow.b)
        XCTAssertLessThan(
            brightnessWithShadow, brightnessNoShadow,
            "Shadow zone pixel should be darker with shadow enabled"
        )
    }

    // MARK: - Helpers

    private struct PixelRGBA {
        let r: UInt8, g: UInt8, b: UInt8, alpha: UInt8
    }

    private func getPixel(from image: CGImage, x: Int, y: Int) -> PixelRGBA {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PixelRGBA(r: 0, g: 0, b: 0, alpha: 0)
        }
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return PixelRGBA(r: pixel[0], g: pixel[1], b: pixel[2], alpha: pixel[3])
    }
}
