import XCTest
@testable import Caloura

@MainActor
final class RegionSelectionViewTests: XCTestCase {

    func testIsDimmingSuppressed_setsTrueHidesDimmingAndHint() {
        let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        view.isDimmingSuppressed = true

        let dimmingLayer = view.layer!.sublayers![1] as! CAShapeLayer
        let hintContainer = view.layer!.sublayers![4]
        XCTAssertEqual(dimmingLayer.opacity, 0)
        XCTAssertEqual(hintContainer.opacity, 0)
    }

    func testIsDimmingSuppressed_setsFalseRestoresDimmingAndHint() {
        let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.isDimmingSuppressed = true

        view.isDimmingSuppressed = false

        let dimmingLayer = view.layer!.sublayers![1] as! CAShapeLayer
        let hintContainer = view.layer!.sublayers![4]
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

        let dimmingLayer = view.layer!.sublayers![1] as! CAShapeLayer
        XCTAssertEqual(dimmingLayer.opacity, 1)
    }
}
