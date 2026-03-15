import XCTest
@testable import Caloura

@MainActor
final class CaptureOverlayWindowPoolTests: XCTestCase {

    // MARK: - Tests

    func testAcquireReturnsWindowsMatchingScreenCount() {
        let pool = CaptureOverlayWindowPool()
        let windows = pool.acquire(cursorController: nil)

        XCTAssertFalse(windows.isEmpty)
        XCTAssertEqual(windows.count, NSScreen.screens.count)

        pool.tearDown()
    }

    func testAcquireReusesWindowsWhenScreensUnchanged() {
        let pool = CaptureOverlayWindowPool()

        let first = pool.acquire(cursorController: nil)
        let second = pool.acquire(cursorController: nil)

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertTrue(a === b, "Expected same window instance on second acquire")
        }

        pool.tearDown()
    }

    func testAcquireTearDownRecreatesAfterTearDown() {
        let pool = CaptureOverlayWindowPool()

        let first = pool.acquire(cursorController: nil)
        pool.tearDown()
        let second = pool.acquire(cursorController: nil)

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertFalse(a === b, "Expected new window instances after tearDown")
        }

        pool.tearDown()
    }

    func testReleaseHidesWindowsButRetainsPool() {
        let pool = CaptureOverlayWindowPool()

        let first = pool.acquire(cursorController: nil)
        pool.release()

        for window in first {
            XCTAssertFalse(window.isVisible, "Window should be hidden after release")
        }

        let second = pool.acquire(cursorController: nil)

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertTrue(a === b, "Expected same window instances reused after release")
        }

        pool.tearDown()
    }

    func testAcquireWithDifferentCursorControllerUpdatesWindows() {
        let pool = CaptureOverlayWindowPool()
        let spyA = PoolCursorSpy()
        let spyB = PoolCursorSpy()

        let first = pool.acquire(cursorController: spyA)
        let second = pool.acquire(cursorController: spyB)

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertTrue(a === b, "Expected same window instances when only cursor controller changes")
        }

        pool.tearDown()
    }
}

// MARK: - Spy

@MainActor
private final class PoolCursorSpy: CaptureCursorControlling {
    func beginCrosshairSession() {}
    func reassertCrosshair() {}
    func endCrosshairSession() {}
}
