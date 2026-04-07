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

    func testCaptureWindow_failedToStartRoutesPermissionFailure() async {
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
            resumedMode == .window
        }

        XCTAssertEqual(resumedMode, .window)
        XCTAssertFalse(pipeline.appState.isCapturing)
    }
}
