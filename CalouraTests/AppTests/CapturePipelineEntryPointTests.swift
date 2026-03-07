import XCTest
@testable import Caloura

@MainActor
extension CapturePipelineTests {
    func testCaptureArea_entrypointPresentsInjectedCoordinator() {
        var areaSession: FakeAreaCaptureSession?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeAreaCaptureSession: { _, onSelection, onCancel, onFirstInteraction in
                let session = FakeAreaCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel,
                    onFirstInteraction: onFirstInteraction
                )
                areaSession = session
                return session
            },
            freezeScreensEnabled: false
        )

        pipeline.captureArea()

        XCTAssertEqual(areaSession?.presentCalls, 1)
        XCTAssertFalse(areaSession?.lastSuppressDimming ?? true)
        XCTAssertTrue(pipeline.appState.isCapturing)
    }

    func testCaptureArea_cancelledViaCoordinatorClearsCaptureState() {
        var areaSession: FakeAreaCaptureSession?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeAreaCaptureSession: { _, onSelection, onCancel, onFirstInteraction in
                let session = FakeAreaCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel,
                    onFirstInteraction: onFirstInteraction
                )
                areaSession = session
                return session
            },
            freezeScreensEnabled: false
        )

        pipeline.captureArea()

        XCTAssertEqual(areaSession?.presentCalls, 1)

        areaSession?.triggerCancel()

        XCTAssertFalse(pipeline.appState.isCapturing)
        XCTAssertNil(pipeline.areaCaptureSession)
    }

    func testCaptureArea_selectionRunsLiveAreaCapture() async throws {
        let captureManager = FakeScreenCaptureManager()
        var areaSession: FakeAreaCaptureSession?
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
            freezeScreensEnabled: false
        )
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)

        pipeline.captureArea()
        XCTAssertEqual(areaSession?.presentCalls, 1)
        await areaSession?.triggerSelection(
            rect: CGRect(x: 10, y: 12, width: 80, height: 60),
            screen: screen,
            frozenImage: nil
        )

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(captureManager.areaCalls, 1)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .area)
    }

    func testCaptureArea_selectionUsesFrozenImageCropPath() async throws {
        var areaSession: FakeAreaCaptureSession?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeAreaCaptureSession: { _, onSelection, onCancel, onFirstInteraction in
                let session = FakeAreaCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel,
                    onFirstInteraction: onFirstInteraction
                )
                areaSession = session
                return session
            },
            freezeScreensEnabled: false
        )
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let scale = Int(screen.backingScaleFactor)
        let frozenImage = TestImageFactory.makeTestImage(
            width: max(1, Int(screen.frame.width) * scale),
            height: max(1, Int(screen.frame.height) * scale)
        )

        pipeline.captureArea()
        XCTAssertEqual(areaSession?.presentCalls, 1)
        await areaSession?.triggerSelection(
            rect: CGRect(x: 20, y: 24, width: 80, height: 60),
            screen: screen,
            frozenImage: frozenImage
        )

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(pipeline.appState.lastScreenshot?.cgImage.width, 80 * scale)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.cgImage.height, 60 * scale)
    }

    func testCaptureArea_freezeEnabledPresentsWithSuppressedDimmingThenUpdates() async {
        let captureManager = FakeScreenCaptureManager()
        var areaSession: FakeAreaCaptureSession?
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

        // Phase 1: present is synchronous with dimming suppressed
        XCTAssertEqual(areaSession?.presentCalls, 1)
        XCTAssertTrue(areaSession?.lastSuppressDimming ?? false)

        // Phase 2: frozen images arrive asynchronously
        await pollUntil(timeout: 2.0) {
            areaSession?.updateFrozenImagesCalls == 1
        }

        XCTAssertEqual(areaSession?.updateFrozenImagesCalls, 1)
        XCTAssertGreaterThanOrEqual(captureManager.fullScreenCalls, 1)
    }

    func testCaptureFullscreen_singleDisplayUsesInjectedCaptureManager() async {
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            screenCountProvider: { 1 }
        )

        pipeline.captureFullscreen()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(captureManager.fullScreenCalls, 1)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .fullscreen)
    }

    func testCaptureFullscreen_multiDisplayPresentsInjectedCoordinator() {
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

        XCTAssertEqual(fullscreenSession?.presentCalls, 1)
        XCTAssertTrue(pipeline.appState.isCapturing)
    }

    func testCaptureFullscreen_multiDisplaySelectionPerformsCapture() async throws {
        let captureManager = FakeScreenCaptureManager()
        var fullscreenSession: FakeFullscreenCaptureSession?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
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
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)

        pipeline.captureFullscreen()
        await fullscreenSession?.triggerSelection(screen: screen)

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot?.context.mode == .fullscreen
        }

        XCTAssertEqual(captureManager.fullScreenCalls, 1)
        XCTAssertNil(pipeline.fullscreenCaptureSession)
    }

    func testCaptureWindow_usesInjectedWindowSessionFactory() async {
        let expectedImage = TestImageFactory.makeTestImage(width: 210, height: 120)
        let fakeSession = FakeWindowCaptureSession(result: .selected { expectedImage })
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeWindowCaptureSession: { _, _, _ in
                fakeSession
            }
        )

        pipeline.captureWindow()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(fakeSession.pickCalls, 1)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.cgImage.width, expectedImage.width)
    }

    func testCaptureWindow_cancelledClearsCaptureState() async {
        let fakeSession = FakeWindowCaptureSession(result: .cancelled)
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeWindowCaptureSession: { _, _, _ in
                fakeSession
            }
        )

        pipeline.captureWindow()

        await pollUntil(timeout: 2.0) {
            !pipeline.appState.isCapturing
        }

        XCTAssertEqual(fakeSession.pickCalls, 1)
        XCTAssertNil(pipeline.appState.lastScreenshot)
    }

    func testCaptureWindow_failedToStartInvokesPermissionFailureHandler() async {
        var permissionFailureCount = 0
        let fakeSession = FakeWindowCaptureSession(result: .failedToStart)
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: {
                permissionFailureCount += 1
            },
            makeWindowCaptureSession: { _, _, _ in
                fakeSession
            }
        )

        pipeline.captureWindow()

        await pollUntil(timeout: 2.0) {
            permissionFailureCount == 1 && !pipeline.appState.isCapturing
        }

        XCTAssertEqual(fakeSession.pickCalls, 1)
        XCTAssertEqual(permissionFailureCount, 1)
    }

    func testCaptureRepeat_usesStoredAreaSelection() async throws {
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager
        )
        pipeline.appState.lastCaptureRect = CGRect(x: 10, y: 20, width: 120, height: 80)
        pipeline.appState.lastCaptureScreen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)

        pipeline.captureRepeat()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(captureManager.areaCalls, 1)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .area)
    }

    func testCaptureRepeat_withoutPreviousAreaSelectionShowsStatus() {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function
        )

        pipeline.captureRepeat()

        XCTAssertEqual(
            pipeline.appState.statusMessage,
            "No previous area capture to repeat."
        )
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    func testCaptureDelayed_areaDispatchesToAreaEntrypoint() async {
        var areaSession: FakeAreaCaptureSession?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeAreaCaptureSession: { _, onSelection, onCancel, onFirstInteraction in
                let session = FakeAreaCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel,
                    onFirstInteraction: onFirstInteraction
                )
                areaSession = session
                return session
            },
            freezeScreensEnabled: false
        )

        pipeline.captureDelayed(seconds: 1, mode: .area)

        await pollUntil(timeout: 3.0) {
            areaSession?.presentCalls == 1
        }

        XCTAssertEqual(areaSession?.presentCalls, 1)
        XCTAssertFalse(pipeline.appState.isCountingDown)
    }

    func testCaptureDelayed_fullscreenDispatchesToCaptureManager() async {
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            screenCountProvider: { 1 }
        )

        pipeline.captureDelayed(seconds: 1, mode: .fullscreen)

        await pollUntil(timeout: 3.0) {
            pipeline.appState.lastScreenshot?.context.mode == .fullscreen
        }

        XCTAssertEqual(captureManager.fullScreenCalls, 1)
        XCTAssertFalse(pipeline.appState.isCountingDown)
    }

    func testCancelDelayedCapture_clearsCountdownState() async {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function
        )

        pipeline.captureDelayed(seconds: 2, mode: .area)
        pipeline.cancelDelayedCapture()

        await pollUntil(timeout: 3.0) {
            !pipeline.appState.isCountingDown
        }

        XCTAssertFalse(pipeline.appState.isCountingDown)
        XCTAssertEqual(pipeline.appState.countdownRemaining, 0)
        XCTAssertNil(pipeline.delayedCaptureTask)
    }
}
