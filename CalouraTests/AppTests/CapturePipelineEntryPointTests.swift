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

        pipeline.entrypointService.captureArea()

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

        pipeline.entrypointService.captureArea()

        XCTAssertEqual(areaSession?.presentCalls, 1)

        areaSession?.triggerCancel()

        XCTAssertFalse(pipeline.appState.isCapturing)
        XCTAssertNil(pipeline.sessionState.areaCaptureSession)
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

        pipeline.entrypointService.captureArea()
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

        pipeline.entrypointService.captureArea()
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

        pipeline.entrypointService.captureArea()

        // Phase 1: present is synchronous with dimming suppressed
        XCTAssertEqual(areaSession?.presentCalls, 1)
        XCTAssertTrue(areaSession?.lastSuppressDimming ?? false)

        // Phase 2: frozen images arrive asynchronously
        await pollUntil(timeout: 2.0) {
            areaSession?.updateFrozenImagesCalls == 1
        }

        XCTAssertEqual(areaSession?.updateFrozenImagesCalls, 1)
        XCTAssertGreaterThanOrEqual(captureManager.frozenSnapshotCalls, 1)
    }

    func testCaptureFullscreen_singleDisplayUsesInjectedCaptureManager() async {
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            screenCountProvider: { 1 }
        )

        pipeline.entrypointService.captureFullscreen()

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

        pipeline.entrypointService.captureFullscreen()

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

        pipeline.entrypointService.captureFullscreen()
        await fullscreenSession?.triggerSelection(screen: screen)

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot?.context.mode == .fullscreen
        }

        XCTAssertEqual(captureManager.fullScreenCalls, 1)
        XCTAssertNil(pipeline.sessionState.fullscreenCaptureSession)
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

        pipeline.entrypointService.captureWindow()

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

        pipeline.entrypointService.captureWindow()

        await pollUntil(timeout: 2.0) {
            !pipeline.appState.isCapturing
        }

        XCTAssertEqual(fakeSession.pickCalls, 1)
        XCTAssertNil(pipeline.appState.lastScreenshot)
    }

    func testCaptureWindow_failedToStartDoesNotInvokePermissionFailureHandler() async {
        // Picker `.failedToStart` is treated as a transient failure. The
        // permission-repair flow is destructive (modal alert, TCC reset,
        // forced relaunch) — gated on genuine denial evidence, not a
        // single picker hiccup.
        var resumedMode: CaptureMode?
        let fakeSession = FakeWindowCaptureSession(result: .failedToStart)
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: { mode in
                resumedMode = mode
            },
            makeWindowCaptureSession: { _, _, _ in
                fakeSession
            }
        )

        pipeline.entrypointService.captureWindow()

        await pollUntil(timeout: 2.0) {
            !pipeline.appState.isCapturing
        }

        XCTAssertEqual(fakeSession.pickCalls, 1)
        XCTAssertNil(resumedMode, "failedToStart must not trigger permission repair")
        XCTAssertTrue(
            pipeline.appState.statusMessage.contains("picker"),
            "expected soft picker-unavailable status; got \(pipeline.appState.statusMessage)"
        )
    }

    func testCaptureRepeat_usesStoredAreaSelection() async throws {
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager
        )
        pipeline.appState.lastCaptureRect = CGRect(x: 10, y: 20, width: 120, height: 80)
        pipeline.appState.lastCaptureScreen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)

        pipeline.entrypointService.captureRepeat()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(captureManager.areaCalls, 1)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .area)
    }

    func testCaptureRepeat_clearsStaleScreenReferenceWhenScreenNoLongerPresent() async throws {
        // Simulates a monitor unplug between the original area capture and
        // the repeat: `lastCaptureScreen` still points at the now-disconnected
        // NSScreen instance. captureRepeat must recognize the stale reference,
        // clear it, and fall back to mainScreenProvider() rather than try to
        // capture from a screen that's no longer in the layout.
        let captureManager = FakeScreenCaptureManager()
        let realScreen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            screensProvider: { [] },
            mainScreenProvider: { realScreen }
        )
        pipeline.appState.lastCaptureRect = CGRect(x: 10, y: 20, width: 120, height: 80)
        pipeline.appState.lastCaptureScreen = realScreen

        pipeline.entrypointService.captureRepeat()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertNil(
            pipeline.appState.lastCaptureScreen,
            "stale screen reference must be cleared when the screen is no longer present"
        )
        XCTAssertEqual(captureManager.areaCalls, 1)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .area)
    }

    func testCaptureRepeat_withoutPreviousAreaSelectionShowsStatus() {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function
        )

        pipeline.entrypointService.captureRepeat()

        XCTAssertEqual(
            pipeline.appState.statusMessage,
            "No previous area capture to repeat."
        )
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    func testCaptureDelayed_usesInjectedClockToAdvanceCountdownInstantly() async {
        // The countdown loop sleeps between ticks via the injected sleeper.
        // Tests substitute a no-op sleeper so we can advance through a 5s
        // countdown without waiting 5 real seconds and without the test
        // depending on wall-clock timing.
        let captureManager = FakeScreenCaptureManager()
        let sleeperCount = SleeperCounter()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            screenCountProvider: { 1 },
            delaySleeper: { _ in
                sleeperCount.increment()
            }
        )

        let started = Date()
        pipeline.entrypointService.captureDelayed(seconds: 5, mode: .fullscreen)

        await pollUntil(timeout: 1.0) {
            pipeline.appState.lastScreenshot?.context.mode == .fullscreen
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 0.5,
            "injected sleeper must short-circuit the countdown — elapsed \(elapsed)s"
        )
        XCTAssertEqual(captureManager.fullScreenCalls, 1)
        XCTAssertFalse(pipeline.appState.isCountingDown)
        XCTAssertEqual(
            sleeperCount.value, 5,
            "delaySleeper must be invoked once per countdown tick"
        )
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

        pipeline.entrypointService.captureDelayed(seconds: 1, mode: .area)

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

        pipeline.entrypointService.captureDelayed(seconds: 1, mode: .fullscreen)

        await pollUntil(timeout: 3.0) {
            pipeline.appState.lastScreenshot?.context.mode == .fullscreen
        }

        XCTAssertEqual(captureManager.fullScreenCalls, 1)
        XCTAssertFalse(pipeline.appState.isCountingDown)
    }

    func testCaptureFullscreen_emptyOverlaysAbortsAndClearsCaptureState() async {
        var fullscreenSession: FakeFullscreenCaptureSession?
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            makeFullscreenCaptureSession: { _, onSelection, onCancel in
                let session = FakeFullscreenCaptureSession(
                    onSelection: onSelection,
                    onCancel: onCancel
                )
                session.simulatedOverlayCount = 0
                fullscreenSession = session
                return session
            },
            screenCountProvider: { 2 }
        )

        pipeline.entrypointService.captureFullscreen()

        await pollUntil(timeout: 1.0) {
            !pipeline.appState.isCapturing
        }

        XCTAssertEqual(fullscreenSession?.presentCalls, 1)
        XCTAssertEqual(fullscreenSession?.dismissCalls, 1)
        XCTAssertFalse(pipeline.appState.isCapturing)
        XCTAssertEqual(
            pipeline.appState.statusMessage,
            "No active display — capture cancelled."
        )
    }

    func testCaptureWindow_lowProfileGuardDoesNotClearIsCapturingDuringActiveCapture() async {
        // Regression: the low-profile early-return in captureWindow() must
        // not reset isCapturing — only the owner that acquired the flag via
        // beginCaptureIfIdle() may clear it. Otherwise a window-capture
        // hotkey press mid-capture silently admits a concurrent capture.
        let fakeSession = FakeWindowCaptureSession(result: .selected {
            TestImageFactory.makeTestImage(width: 100, height: 100)
        })
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(#function)-\(UUID().uuidString)")!)
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            settings: settings,
            makeWindowCaptureSession: { _, _, _ in fakeSession }
        )

        pipeline.appState.isCapturing = true
        settings.lowProfileCaptureEnabled = true

        pipeline.entrypointService.captureWindow()

        XCTAssertTrue(
            pipeline.appState.isCapturing,
            "low-profile early-return must not clear isCapturing owned by another capture"
        )
        XCTAssertEqual(fakeSession.pickCalls, 0, "window picker must not run in low-profile mode")
        XCTAssertEqual(
            pipeline.appState.statusMessage,
            "Window capture unavailable in low-profile mode"
        )
    }

    func testCancelDelayedCapture_clearsCountdownState() async {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function
        )

        pipeline.entrypointService.captureDelayed(seconds: 2, mode: .area)
        pipeline.entrypointService.cancelDelayedCapture()

        await pollUntil(timeout: 5.0) {
            !pipeline.appState.isCountingDown
        }

        XCTAssertFalse(pipeline.appState.isCountingDown)
        XCTAssertEqual(pipeline.appState.countdownRemaining, 0)
        XCTAssertNil(pipeline.sessionState.delayedCaptureTask)
    }
}

/// Lock-protected counter for asserting how many times the injected
/// captureDelayed sleeper was invoked.
final class SleeperCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
