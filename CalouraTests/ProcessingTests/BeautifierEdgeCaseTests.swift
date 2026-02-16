import XCTest
@testable import Caloura

final class BeautifierEdgeCaseTests: XCTestCase {

    func testBeautify_tinyImage_1x1() async {
        let image = TestImageFactory.makeTestImage(width: 1, height: 1)
        let theme = BeautifyTheme.builtInThemes[0]
        let result = await Beautifier.beautify(cgImage: image, theme: theme)
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
    }

    func testBeautify_largeImage_4096x4096() async {
        let image = TestImageFactory.makeTestImage(width: 4096, height: 4096)
        let theme = BeautifyTheme.builtInThemes[0]

        let start = CFAbsoluteTimeGetCurrent()
        let result = await Beautifier.beautify(cgImage: image, theme: theme)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertGreaterThan(result.width, 4096)
        XCTAssertLessThan(elapsed, 5.0, "Large image beautification should complete within 5s")
    }

    func testBeautify_singleColorGradient() async {
        let image = TestImageFactory.makeTestImage(width: 100, height: 100)
        var theme = BeautifyTheme.builtInThemes[0]
        theme.gradientColors = [CodableColor(red: 0.5, green: 0.5, blue: 0.5)]
        let result = await Beautifier.beautify(cgImage: image, theme: theme)
        XCTAssertGreaterThan(result.width, 0, "Single-color gradient should not crash")
    }
}
