import XCTest
@testable import Caloura

@MainActor
extension CapturePipelineTests {
    func testCaptureArea_cancelledBeforeFrozenImagesArriveSkipsStaleUpdate() async {
        let captureManager = FakeScreenCaptureManager()
        var areaSession: FakeAreaCaptureSession?
        var freezeStartedRecorded = false
        let freezeStarted = expectation(description: "freeze started")
        freezeStarted.assertForOverFulfill = false
        let freezeCompleted = expectation(description: "freeze completed")
        freezeCompleted.expectedFulfillmentCount = max(1, NSScreen.screens.count)
        let releaseFrozenSnapshots = AsyncGate()

        captureManager.frozenSnapshotHandler = { _ in
            if !freezeStartedRecorded {
                freezeStartedRecorded = true
                freezeStarted.fulfill()
            }
            await releaseFrozenSnapshots.wait()
            freezeCompleted.fulfill()
            return TestImageFactory.makeTestImage(width: 125, height: 95)
        }

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            makeAreaCaptureSession: { _, onSelection, onCancel, onFirstInteraction in
                let session = FakeAreaCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel,
                    onFirstInteraction: onFirstInteraction
                )
                areaSession = session
                return session
            },
            freezeScreensEnabled: true
        )

        pipeline.captureArea()

        await fulfillment(of: [freezeStarted], timeout: 2.0)
        areaSession?.triggerCancel()
        await releaseFrozenSnapshots.open()
        await fulfillment(of: [freezeCompleted], timeout: 2.0)

        XCTAssertFalse(pipeline.appState.isCapturing)
        XCTAssertNil(pipeline.sessionState.areaCaptureSession)
        XCTAssertEqual(areaSession?.updateFrozenImagesCalls, 0)
    }

    func testCaptureFullscreen_multiDisplayCancellationClearsCaptureState() {
        var fullscreenSession: FakeFullscreenCaptureSession?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeFullscreenCaptureSession: { _, onSelection, onCancel in
                let session = FakeFullscreenCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel
                )
                fullscreenSession = session
                return session
            },
            screenCountProvider: { 2 }
        )

        pipeline.captureFullscreen()
        fullscreenSession?.triggerCancel()

        XCTAssertFalse(pipeline.appState.isCapturing)
        XCTAssertNil(pipeline.sessionState.fullscreenCaptureSession)
    }

    func testCaptureArea_freezeTimeoutStillUpdatesSessionWithoutBlockingEntry() async {
        let captureManager = FakeScreenCaptureManager()
        var areaSession: FakeAreaCaptureSession?
        let freezeCancelled = expectation(description: "freeze cancelled")
        freezeCancelled.expectedFulfillmentCount = max(1, NSScreen.screens.count)
        captureManager.frozenSnapshotHandler = { _ in
            do {
                try await Task.sleep(for: .seconds(30))
                return TestImageFactory.makeTestImage(width: 125, height: 95)
            } catch is CancellationError {
                freezeCancelled.fulfill()
                throw CaptureError.cancelled
            } catch {
                throw error
            }
        }

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            makeAreaCaptureSession: { _, onSelection, onCancel, onFirstInteraction in
                let session = FakeAreaCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel,
                    onFirstInteraction: onFirstInteraction
                )
                areaSession = session
                return session
            },
            freezeScreensEnabled: true,
            freezeSnapshotTimeoutSeconds: 0.01
        )

        pipeline.captureArea()

        XCTAssertEqual(areaSession?.presentCalls, 1)
        await pollUntil(timeout: 1.0) {
            areaSession?.updateFrozenImagesCalls == 1
        }
        await fulfillment(of: [freezeCancelled], timeout: 2.0)

        XCTAssertEqual(areaSession?.updateFrozenImagesCalls, 1)
        XCTAssertTrue(pipeline.appState.isCapturing)
    }

    func testCaptureDelayed_completionClearsDelayedTaskReference() async {
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            screenCountProvider: { 1 }
        )

        pipeline.captureDelayed(seconds: 1, mode: .fullscreen)

        await pollUntil(timeout: 3.0) {
            pipeline.appState.lastScreenshot?.context.mode == .fullscreen
                && !pipeline.appState.isCountingDown
                && pipeline.sessionState.delayedCaptureTask == nil
        }

        XCTAssertNil(pipeline.sessionState.delayedCaptureTask)
    }

}
