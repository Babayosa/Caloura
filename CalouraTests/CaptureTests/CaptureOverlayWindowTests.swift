import XCTest
@testable import Caloura

@MainActor
final class CaptureOverlayWindowTests: XCTestCase {

    private func makeWindow() throws -> CaptureOverlayWindow {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available")
        }
        return CaptureOverlayWindow(for: screen, cursorController: nil)
    }

    // MARK: - Bridge closure invariant

    func testAreaOverlayWindowIsBorderlessForScreenAlignedCoordinates() throws {
        let window = try makeWindow()

        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(window.sharingType, .none)
    }

    func testScreenSelectionOverlayWindowIsBorderlessForScreenAlignedCoordinates() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available")
        }
        let window = ScreenSelectionOverlayWindow(for: screen, cursorController: nil)

        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(window.sharingType, .none)
    }

    func testTearDownHandlersPreservesBridgeClosures() throws {
        let window = try makeWindow()
        let selectionView = try XCTUnwrap(window.contentView as? RegionSelectionView)

        // Bridge closures are installed in init
        XCTAssertNotNil(selectionView.onRegionSelected)
        XCTAssertNotNil(selectionView.onCancelled)
        XCTAssertNotNil(selectionView.onFirstMouseDown)

        window.tearDownHandlers()

        // Window-level callbacks are nil
        XCTAssertNil(window.onRegionSelected)
        XCTAssertNil(window.onCancelled)
        XCTAssertNil(window.onFirstMouseDown)

        // Bridge closures must survive for reuse
        XCTAssertNotNil(selectionView.onRegionSelected,
                        "Bridge closures must survive teardown")
        XCTAssertNotNil(selectionView.onCancelled,
                        "Bridge closures must survive teardown")
        XCTAssertNotNil(selectionView.onFirstMouseDown,
                        "Bridge closures must survive teardown")
    }

    // MARK: - Frozen-image release (leak fix)

    func testTearDownHandlersReleasesFrozenImage() throws {
        let window = try makeWindow()
        let selectionView = try XCTUnwrap(window.contentView as? RegionSelectionView)
        let image = TestImageFactory.makeTestImage(width: 64, height: 64)

        // Production reveals the frozen snapshot via revealFrozenImage, which
        // writes selectionView.frozenImage (and its backing layer) directly —
        // the exact reference a pooled/closed overlay would otherwise pin.
        window.revealFrozenImage(image)
        XCTAssertNotNil(selectionView.frozenImage)
        XCTAssertNotNil(selectionView.backgroundLayer.contents)

        window.tearDownHandlers()

        XCTAssertNil(window.frozenImage,
                     "Window must drop its frozen-image reference on teardown")
        XCTAssertNil(selectionView.frozenImage,
                     "Pooled overlay must not pin the full-screen frozen image")
        XCTAssertNil(selectionView.backgroundLayer.contents,
                     "Backing layer must release the display-sized bytes")
    }

    func testWindowFrozenImageAssignmentCascadesToViewThenClears() throws {
        let window = try makeWindow()
        let selectionView = try XCTUnwrap(window.contentView as? RegionSelectionView)
        let image = TestImageFactory.makeTestImage(width: 64, height: 64)

        window.frozenImage = image
        XCTAssertNotNil(selectionView.frozenImage,
                        "Window frozenImage didSet should cascade to the view")

        window.tearDownHandlers()
        XCTAssertNil(window.frozenImage)
        XCTAssertNil(selectionView.frozenImage)
    }

    func testReusedWindowForwardsCallbacksThroughBridgeClosures() throws {
        let window = try makeWindow()
        let selectionView = try XCTUnwrap(window.contentView as? RegionSelectionView)

        // Simulate first-capture teardown
        window.resetForReuse(cursorController: nil)

        // Simulate second capture: set new window-level callbacks
        var regionFired = false
        var cancelFired = false
        var firstMouseFired = false
        window.onRegionSelected = { _, _ in regionFired = true }
        window.onCancelled = { cancelFired = true }
        window.onFirstMouseDown = { firstMouseFired = true }

        // Trigger bridge closures on selectionView (simulates user interaction)
        selectionView.onRegionSelected?(CGRect(x: 10, y: 10, width: 100, height: 100))
        selectionView.onCancelled?()
        selectionView.onFirstMouseDown?()

        XCTAssertTrue(regionFired,
                      "Bridge closure should forward to new window callback after reuse")
        XCTAssertTrue(cancelFired,
                      "Bridge closure should forward to new window callback after reuse")
        XCTAssertTrue(firstMouseFired,
                      "Bridge closure should forward to new window callback after reuse")
    }
}
