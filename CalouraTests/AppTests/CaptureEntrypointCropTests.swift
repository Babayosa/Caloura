import XCTest
@testable import Caloura

@MainActor
final class CaptureEntrypointCropTests: XCTestCase {

    // MARK: - 2× Retina (standard)

    func testFrozenCropRect_2xRetina() {
        // 2560px image on 1280pt screen → scale 2.0
        let rect = CaptureEntrypointService.frozenImageCropRect(
            selectionRect: CGRect(x: 100, y: 100, width: 200, height: 150),
            screenHeight: 800,
            imageWidth: 2560,
            screenWidth: 1280
        )

        XCTAssertEqual(rect.origin.x, 200) // 100 * 2
        XCTAssertEqual(rect.origin.y, 1100) // (800 - 100 - 150) * 2
        XCTAssertEqual(rect.width, 400) // 200 * 2
        XCTAssertEqual(rect.height, 300) // 150 * 2
    }

    // MARK: - 1× point delivery (warm-up edge case)

    func testFrozenCropRect_1xPointDelivery() {
        // 1280px image on 1280pt screen → scale 1.0
        let rect = CaptureEntrypointService.frozenImageCropRect(
            selectionRect: CGRect(x: 100, y: 100, width: 200, height: 150),
            screenHeight: 800,
            imageWidth: 1280,
            screenWidth: 1280
        )

        XCTAssertEqual(rect.origin.x, 100)
        XCTAssertEqual(rect.origin.y, 550) // 800 - 100 - 150
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 150)
    }

    // MARK: - Non-standard scale

    func testFrozenCropRect_nonStandardScale() {
        // 1920px image on 1280pt screen → scale 1.5
        let rect = CaptureEntrypointService.frozenImageCropRect(
            selectionRect: CGRect(x: 100, y: 100, width: 200, height: 200),
            screenHeight: 800,
            imageWidth: 1920,
            screenWidth: 1280
        )

        XCTAssertEqual(rect.origin.x, 150) // 100 * 1.5
        XCTAssertEqual(rect.origin.y, 750) // (800 - 100 - 200) * 1.5
        XCTAssertEqual(rect.width, 300) // 200 * 1.5
        XCTAssertEqual(rect.height, 300) // 200 * 1.5
    }

    // MARK: - Selection at origin (top-left in screen coordinates)

    func testFrozenCropRect_selectionAtOrigin() {
        // Selection at (0, 0) in view coords = bottom-left of screen
        // flippedY should place it at the bottom of the image
        let rect = CaptureEntrypointService.frozenImageCropRect(
            selectionRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenHeight: 800,
            imageWidth: 2560,
            screenWidth: 1280
        )

        XCTAssertEqual(rect.origin.x, 0)
        XCTAssertEqual(rect.origin.y, 1400) // (800 - 0 - 100) * 2
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 200)
    }

    // MARK: - Selection at top-right corner

    func testFrozenCropRect_selectionAtTopRight() {
        // Selection at top-right of the screen
        let rect = CaptureEntrypointService.frozenImageCropRect(
            selectionRect: CGRect(x: 1180, y: 700, width: 100, height: 100),
            screenHeight: 800,
            imageWidth: 2560,
            screenWidth: 1280
        )

        XCTAssertEqual(rect.origin.x, 2360) // 1180 * 2
        XCTAssertEqual(rect.origin.y, 0) // (800 - 700 - 100) * 2
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 200)
    }

    // MARK: - Full screen selection

    func testFrozenCropRect_fullScreen() {
        let rect = CaptureEntrypointService.frozenImageCropRect(
            selectionRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
            screenHeight: 800,
            imageWidth: 2560,
            screenWidth: 1280
        )

        XCTAssertEqual(rect.origin.x, 0)
        XCTAssertEqual(rect.origin.y, 0)
        XCTAssertEqual(rect.width, 2560)
        XCTAssertEqual(rect.height, 1600)
    }
}
