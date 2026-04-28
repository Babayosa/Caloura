import XCTest
@testable import Caloura

@MainActor
final class RegionSelectionViewTests: XCTestCase {

    func testIsDimmingSuppressed_setsTrueHidesDimmingAndHint() {
        let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        view.isDimmingSuppressed = true

        guard let dimmingLayer = view.layer?.sublayers?[1] as? CAShapeLayer else {
            return XCTFail("Expected dimming layer")
        }
        guard let hintContainer = view.layer?.sublayers?[4] else {
            return XCTFail("Expected hint container layer")
        }
        XCTAssertEqual(dimmingLayer.opacity, 0)
        XCTAssertEqual(hintContainer.opacity, 0)
    }

    func testIsDimmingSuppressed_setsFalseRestoresDimmingAndHint() {
        let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.isDimmingSuppressed = true

        view.isDimmingSuppressed = false

        guard let dimmingLayer = view.layer?.sublayers?[1] as? CAShapeLayer else {
            return XCTFail("Expected dimming layer")
        }
        guard let hintContainer = view.layer?.sublayers?[4] else {
            return XCTFail("Expected hint container layer")
        }
        XCTAssertEqual(dimmingLayer.opacity, 1)
        XCTAssertEqual(hintContainer.opacity, 1)
    }

    func testRevealFrozenImage_setsFrozenImageAndUnsuppresses() {
        let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.isDimmingSuppressed = true

        let image = TestImageFactory.makeTestImage(width: 800, height: 600)
        view.revealFrozenImage(image)

        XCTAssertNotNil(view.frozenImage)
        XCTAssertFalse(view.isDimmingSuppressed)

        guard let dimmingLayer = view.layer?.sublayers?[1] as? CAShapeLayer else {
            return XCTFail("Expected dimming layer")
        }
        XCTAssertEqual(dimmingLayer.opacity, 1)
    }

    func testRegionSelectionViewOwnsCustomCrosshairLayersAboveSelectionUI() {
        let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let sublayers = view.layer?.sublayers ?? []

        XCTAssertEqual(sublayers.count, 7)
        XCTAssertTrue(sublayers[5] is CAShapeLayer)
        XCTAssertTrue(sublayers[6] is CAShapeLayer)
    }
}
