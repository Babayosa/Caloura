import XCTest
@testable import Caloura

@MainActor
final class ScreenCaptureManagerTests: XCTestCase {

    // Create a fresh instance for each test to avoid shared state.
    // ScreenCaptureManager.init() is internal (not private), so direct
    // instantiation is possible. We avoid .shared to prevent test pollution.
    private var sut: ScreenCaptureManager!

    override func setUp() {
        super.setUp()
        sut = ScreenCaptureManager()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testSCKFailed_initiallyFalse() {
        XCTAssertFalse(sut.sckFailed, "sckFailed should be false on a fresh instance")
    }

    // MARK: - resetSCKState

    func testResetSCKState_setsSckFailedToFalse() {
        // Force sckFailed to true via the public property
        sut.sckFailed = true
        XCTAssertTrue(sut.sckFailed)

        sut.resetSCKState()

        XCTAssertFalse(
            sut.sckFailed,
            "resetSCKState should set sckFailed back to false"
        )
    }

    func testResetSCKState_calledMultipleTimes_remainsFalse() {
        sut.sckFailed = true

        sut.resetSCKState()
        sut.resetSCKState()
        sut.resetSCKState()

        XCTAssertFalse(
            sut.sckFailed,
            "Multiple resetSCKState calls should keep sckFailed false"
        )
    }

    func testResetSCKState_whenAlreadyFalse_remainsFalse() {
        XCTAssertFalse(sut.sckFailed)

        sut.resetSCKState()

        XCTAssertFalse(
            sut.sckFailed,
            "resetSCKState on already-false state should remain false"
        )
    }

    // MARK: - captureArea rejects degenerate rects

    func testCaptureArea_zeroWidthRect_throws() async {
        let rect = CGRect(x: 0, y: 0, width: 0, height: 100)

        do {
            _ = try await sut.captureArea(rect: rect)
            XCTFail("captureArea should throw for zero-width rect")
        } catch {
            // Expect CaptureError.captureFailed with message about zero/negative size
            guard case CaptureError.captureFailed(let reason) = error else {
                XCTFail("Expected CaptureError.captureFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                reason.lowercased().contains("zero") || reason.lowercased().contains("negative"),
                "Error reason should mention zero or negative size, got: \(reason)"
            )
        }
    }

    func testCaptureArea_zeroHeightRect_throws() async {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 0)

        do {
            _ = try await sut.captureArea(rect: rect)
            XCTFail("captureArea should throw for zero-height rect")
        } catch {
            guard case CaptureError.captureFailed = error else {
                XCTFail("Expected CaptureError.captureFailed, got \(error)")
                return
            }
        }
    }

    func testCaptureArea_zeroWidthAndHeight_throws() async {
        let rect = CGRect(x: 50, y: 50, width: 0, height: 0)

        do {
            _ = try await sut.captureArea(rect: rect)
            XCTFail("captureArea should throw for zero-size rect")
        } catch {
            guard case CaptureError.captureFailed = error else {
                XCTFail("Expected CaptureError.captureFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - CaptureError descriptions

    func testCaptureError_noPermission_hasDescription() {
        let error = CaptureError.noPermission
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription!.contains("Screen recording permission"),
            "noPermission error should mention screen recording permission"
        )
    }

    func testCaptureError_noDisplay_hasDescription() {
        let error = CaptureError.noDisplay
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("display"))
    }

    func testCaptureError_captureFailed_includesReason() {
        let error = CaptureError.captureFailed("test reason")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription!.contains("test reason"),
            "captureFailed error should include the provided reason"
        )
    }

    func testCaptureError_cancelled_hasDescription() {
        let error = CaptureError.cancelled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("cancelled"))
    }
}
