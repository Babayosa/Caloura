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
