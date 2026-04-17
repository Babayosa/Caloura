import XCTest
@testable import Caloura

@MainActor
extension CapturePipelineTests {
    func testPerformCapture_permissionError() async {
        var resumedMode: CaptureMode?

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: { mode in
                resumedMode = mode
            }
        )

        await pipeline.executionService.performCapture(mode: .area) {
            throw CaptureError.noPermission
        }

        XCTAssertEqual(resumedMode, .area)
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    func testPerformCapture_genericError() async {
        var resumedMode: CaptureMode?

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: { mode in
                resumedMode = mode
            }
        )

        await pipeline.executionService.performCapture(mode: .area) {
            throw CaptureError.captureFailed("test error")
        }

        XCTAssertNil(resumedMode)
        XCTAssertTrue(pipeline.appState.statusMessage.contains("Try again"))
        XCTAssertFalse(pipeline.appState.statusMessage.contains("test error"))
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    func testCaptureWindow_failedToStartDoesNotRoutePermissionFailure() async {
        // Regression guard for the production-grade window-capture overhaul.
        // A picker `.failedToStart` result must NOT cascade into the
        // permission-repair flow — that path greys the menu bar and resets
        // TCC, which is wildly disproportionate for a transient picker
        // hiccup. Surface a status message and let the next hotkey press
        // produce a fresh picker.
        var resumedMode: CaptureMode?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: { mode in
                resumedMode = mode
            },
            selectWindowCapture: { _ in .failedToStart }
        )

        pipeline.captureWindow()

        await pollUntil(timeout: 2.0) {
            !pipeline.appState.isCapturing
        }

        XCTAssertNil(resumedMode, "failedToStart must not trigger permission repair")
        XCTAssertFalse(pipeline.appState.isCapturing)
        XCTAssertTrue(
            pipeline.appState.statusMessage.contains("picker"),
            "expected soft picker-unavailable status; got \(pipeline.appState.statusMessage)"
        )
    }
}
