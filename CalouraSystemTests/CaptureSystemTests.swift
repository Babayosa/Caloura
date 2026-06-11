import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureSystemTests: XCTestCase {
    override nonisolated func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            QuickAccessOverlay.shared.dismiss()
        }
    }

    override nonisolated func tearDown() {
        MainActor.assumeIsolated {
            QuickAccessOverlay.shared.dismiss()
        }
        super.tearDown()
    }

    func testAreaCapturePresentsCrosshairAndHintImmediately() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CursorSpy()
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )
        let windows = makeAreaOverlayWindows(cursorController: cursor)

        coordinator.present(windows: windows)
        defer {
            coordinator.dismiss()
            windows.forEach { $0.close() }
            recorder.finishSession(session)
        }

        XCTAssertEqual(cursor.beginCalls, 1)
        XCTAssertGreaterThan(cursor.reassertCalls, 0)
        XCTAssertFalse(coordinator.overlayWindows.isEmpty)
        XCTAssertEqual(
            recorder.summary(for: .area, event: .overlayVisible)?.sampleCount,
            1
        )

        guard let regionView = coordinator.overlayWindows.first?.contentView as? RegionSelectionView else {
            XCTFail("Expected RegionSelectionView content")
            return
        }
        XCTAssertTrue(regionView.debugHintVisible)
        XCTAssertEqual(regionView.debugHintText, RegionSelectionView.hintText)
    }

    func testAreaCaptureUsesNonactivatingOverlayPanelLevel() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CursorSpy()
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )
        let windows = makeAreaOverlayWindows(cursorController: cursor)

        coordinator.present(windows: windows)
        defer {
            coordinator.dismiss()
            windows.forEach { $0.close() }
            recorder.finishSession(session)
        }

        guard let overlay = coordinator.overlayWindows.first else {
            return XCTFail("Expected overlay window")
        }

        XCTAssertTrue(overlay.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(overlay.level, CaptureOverlayWindow.overlayLevel)
        XCTAssertFalse(overlay.canBecomeMain)
        XCTAssertEqual(coordinator.overlayWindows.filter(\.isKeyWindow).count, 1)
    }

    func testAreaCaptureKeepsMouseScreenOverlayKey() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CursorSpy()
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )
        let windows = makeAreaOverlayWindows(cursorController: cursor)

        coordinator.present(windows: windows)
        defer {
            coordinator.dismiss()
            windows.forEach { $0.close() }
            recorder.finishSession(session)
        }

        let keyOverlays = coordinator.overlayWindows.filter(\.isKeyWindow)
        XCTAssertEqual(keyOverlays.count, 1)

        if let mouseScreen = NSScreen.screens.first(where: { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }) {
            XCTAssertEqual(keyOverlays.first?.screen, mouseScreen)
        }
    }

    func testFullscreenCapturePresentsDisplaySelectionCue() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CursorSpy()
        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _ in },
            onCancel: { }
        )

        coordinator.present()
        defer {
            coordinator.dismiss()
            recorder.finishSession(session)
        }

        XCTAssertEqual(cursor.beginCalls, 1)
        XCTAssertGreaterThan(cursor.reassertCalls, 0)
        XCTAssertFalse(coordinator.overlayWindows.isEmpty)
        XCTAssertEqual(
            recorder.summary(for: .fullscreen, event: .overlayVisible)?.sampleCount,
            1
        )

        guard let selectionView = coordinator.overlayWindows.first?.contentView as? ScreenSelectionView else {
            XCTFail("Expected ScreenSelectionView content")
            return
        }
        XCTAssertEqual(
            selectionView.debugCaptureHintText,
            ScreenSelectionView.captureHintText
        )
        XCTAssertEqual(coordinator.overlayWindows.filter(\.isKeyWindow).count, 1)
    }

    func testWindowCaptureMarksPickerPresentation() async {
        // Regression guard: WindowCaptureSessionCoordinator must NOT activate
        // Caloura before presenting SCContentSharingPicker — doing so steals
        // focus from the target app and can invalidate the filter the picker
        // returns. The coordinator only prewarms content, then hands off to
        // the system picker.
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .window)
        var presented = false
        let coordinator = WindowCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            hasWarmContent: false,
            prewarmContent: { },
            pickWindow: { onPresented in
                onPresented()
                presented = true
                return .cancelled
            }
        )

        let result = await coordinator.pick()
        recorder.finishSession(session)

        if case .cancelled = result {
            // expected
        } else {
            XCTFail("Expected cancelled result")
        }
        XCTAssertTrue(presented)
        XCTAssertTrue(
            recorder.summary(for: .window, event: .pickerVisibleCold) != nil
                || recorder.summary(for: .window, event: .pickerVisibleWarm) != nil
        )
    }

    func testPerformanceRecorder_generatesOverlaySamplesForStrictAudit() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 20, reportInterval: 50)

        for _ in 0..<5 {
            let areaSession = recorder.beginSession(mode: .area)
            let areaCursor = CursorSpy()
            let areaCoordinator = AreaCaptureSessionCoordinator(
                session: areaSession,
                performanceRecorder: recorder,
                cursorController: areaCursor,
                onSelection: { _, _, _ in },
                onCancel: { }
            )
            let areaWindows = makeAreaOverlayWindows(cursorController: areaCursor)
            areaCoordinator.present(windows: areaWindows)
            areaCoordinator.dismiss()
            areaWindows.forEach { $0.close() }
            recorder.finishSession(areaSession)

            let fullscreenSession = recorder.beginSession(mode: .fullscreen)
            let fullscreenCoordinator = FullscreenCaptureSessionCoordinator(
                session: fullscreenSession,
                performanceRecorder: recorder,
                cursorController: CursorSpy(),
                onSelection: { _ in },
                onCancel: { }
            )
            fullscreenCoordinator.present()
            fullscreenCoordinator.dismiss()
            recorder.finishSession(fullscreenSession)
        }

        XCTAssertEqual(recorder.summary(for: .area, event: .overlayVisible)?.sampleCount, 5)
        XCTAssertEqual(recorder.summary(for: .fullscreen, event: .overlayVisible)?.sampleCount, 5)
    }

    func testPerformanceRecorder_generatesPreviewAndPickerSamplesForStrictAudit() async {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 40, reportInterval: 50)
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager,
            capturePerformanceRecorder: recorder
        )
        let image = TestImageFactory.makeTestImage(width: 160, height: 100)

        for _ in 0..<5 {
            let areaSession = recorder.beginSession(mode: .area)
            await pipeline.executionService.performCapture(mode: .area, performanceSession: areaSession) { image }

            let fullscreenSession = recorder.beginSession(mode: .fullscreen)
            await pipeline.executionService.performCapture(
                mode: .fullscreen,
                performanceSession: fullscreenSession
            ) { image }

            let windowSession = recorder.beginSession(mode: .window)
            await pipeline.executionService.performCapture(mode: .window, performanceSession: windowSession) { image }
        }

        for isWarm in [false, true] {
            for _ in 0..<5 {
                let session = recorder.beginSession(mode: .window)
                let coordinator = WindowCaptureSessionCoordinator(
                    session: session,
                    performanceRecorder: recorder,
                    hasWarmContent: isWarm,
                    prewarmContent: { },
                    pickWindow: { onPresented in
                        onPresented()
                        return .cancelled
                    }
                )
                _ = await coordinator.pick()
                recorder.finishSession(session)
            }
        }

        XCTAssertEqual(recorder.summary(for: .area, event: .rawPreviewVisible)?.sampleCount, 5)
        XCTAssertEqual(
            recorder.summary(for: .fullscreen, event: .rawPreviewVisible)?.sampleCount,
            5
        )
        XCTAssertEqual(
            recorder.summary(for: .window, event: .previewPresentationDuration)?.sampleCount,
            5
        )
        XCTAssertEqual(recorder.summary(for: .window, event: .pickerVisibleCold)?.sampleCount, 5)
        XCTAssertEqual(recorder.summary(for: .window, event: .pickerVisibleWarm)?.sampleCount, 5)
    }

    // MARK: - Multi-screen coverage (Phase 3.6)

    func testFullscreenSelectionOnSecondaryOverlayDismissesAllOverlays() async throws {
        // Synthesize a 2-screen layout via the injected overlayPresenter so
        // CI (single physical display) still exercises the multi-overlay
        // dismiss path: selecting from overlay[1] must close every overlay
        // and route the selection to the coordinator's onSelection handler.
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CursorSpy()
        guard let realScreen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("No screen attached (headless runner); multi-screen system test requires a display")
        }

        let onSelectionExpectation = expectation(description: "selection delivered")
        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { selectedScreen in
                XCTAssertEqual(selectedScreen, realScreen)
                onSelectionExpectation.fulfill()
            },
            onCancel: {
                XCTFail("cancel must not fire when selection is made")
            },
            overlayPresenter: { cursorController, onScreenSelected, onCancelled in
                let overlays = (0..<2).map { _ in
                    ScreenSelectionOverlayWindow(
                        for: realScreen,
                        cursorController: cursorController
                    )
                }
                let closeAll = {
                    for overlay in overlays {
                        overlay.onScreenSelected = nil
                        overlay.onCancelled = nil
                        overlay.close()
                    }
                }
                for overlay in overlays {
                    overlay.onScreenSelected = { screen in
                        closeAll()
                        onScreenSelected(screen)
                    }
                    overlay.onCancelled = {
                        closeAll()
                        onCancelled()
                    }
                }
                return overlays
            }
        )

        coordinator.present()
        XCTAssertEqual(coordinator.overlayWindows.count, 2)

        // Trigger selection on the secondary overlay.
        coordinator.overlayWindows[1].onScreenSelected?(realScreen)

        await fulfillment(of: [onSelectionExpectation], timeout: 1.0)

        XCTAssertEqual(cursor.endCalls, 1, "cursor session must end after selection")
        XCTAssertTrue(coordinator.overlayWindows.isEmpty, "all overlays must be cleared")
        recorder.finishSession(session)
    }

    func testFullscreenCancelOnSecondaryOverlayDismissesAllOverlays() async throws {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CursorSpy()
        guard let realScreen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("No screen attached (headless runner); multi-screen system test requires a display")
        }

        let onCancelExpectation = expectation(description: "cancel delivered")
        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _ in
                XCTFail("selection must not fire on cancel")
            },
            onCancel: {
                onCancelExpectation.fulfill()
            },
            overlayPresenter: { cursorController, onScreenSelected, onCancelled in
                let overlays = (0..<2).map { _ in
                    ScreenSelectionOverlayWindow(
                        for: realScreen,
                        cursorController: cursorController
                    )
                }
                let closeAll = {
                    for overlay in overlays {
                        overlay.onScreenSelected = nil
                        overlay.onCancelled = nil
                        overlay.close()
                    }
                }
                for overlay in overlays {
                    overlay.onScreenSelected = { screen in
                        closeAll()
                        onScreenSelected(screen)
                    }
                    overlay.onCancelled = {
                        closeAll()
                        onCancelled()
                    }
                }
                return overlays
            }
        )

        coordinator.present()
        XCTAssertEqual(coordinator.overlayWindows.count, 2)

        coordinator.overlayWindows[1].onCancelled?()

        await fulfillment(of: [onCancelExpectation], timeout: 1.0)

        XCTAssertEqual(cursor.endCalls, 1, "cursor session must end after cancel")
        XCTAssertTrue(coordinator.overlayWindows.isEmpty, "all overlays must be cleared")
        recorder.finishSession(session)
    }

    func testAreaCaptureCrosshairPersistsAcrossFiveCaptures() {
        // Regression guard for the post-ship 2.4.0 crosshair-gone-forever defect.
        // Root cause: pool teardown bypass paths (screen reconfig, abnormal
        // unwind) left cursorActive=true, which trapped later cursor entry.
        // This test asserts five full present/dismiss cycles against real
        // overlay windows each produce a balanced start/end pair.
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 50, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CursorSpy()
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )
        let pool = CaptureOverlayWindowPool()

        defer {
            pool.release()
            recorder.finishSession(session)
        }

        for iteration in 0..<5 {
            let windows = pool.acquire(cursorController: cursor)
            coordinator.present(windows: windows)
            XCTAssertFalse(
                coordinator.overlayWindows.isEmpty,
                "iteration \(iteration): overlays must present"
            )
            coordinator.dismiss()
        }

        XCTAssertGreaterThanOrEqual(cursor.resetCalls, 1)
        XCTAssertEqual(cursor.beginCalls, 5, "each present must begin a cursor session")
        XCTAssertEqual(cursor.endCalls, 5, "each dismiss must end the cursor session")
    }

    func testAreaCaptureCrosshairRecoversAfterPoolTeardownBypass() {
        // D4 regression: simulate the exact bypass path where pool.tearDown()
        // fires outside coordinator.dismiss() (screen reconfiguration). Without
        // resetCursorState() on the pool's release/tearDown, the next start
        // would inherit stale cursor ownership.
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CursorSpy()
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )
        let pool = CaptureOverlayWindowPool()
        defer { recorder.finishSession(session) }

        let firstWindows = pool.acquire(cursorController: cursor)
        coordinator.present(windows: firstWindows)
        // Bypass the coordinator exit: pool teardown without dismiss(). This is
        // the precise failure shape the post-ship regression exhibited.
        pool.tearDown()

        // The next capture must still produce a clean reset + begin.
        let secondWindows = pool.acquire(cursorController: cursor)
        coordinator.present(windows: secondWindows)
        coordinator.dismiss()
        pool.release()

        // Pool teardown contributes one reset (safety net); coordinator.present
        // contributes two more (once per session). The second session must reach
        // begin — if it didn't, the D4 regression would be live again.
        XCTAssertGreaterThanOrEqual(cursor.resetCalls, 3)
        XCTAssertEqual(cursor.beginCalls, 2)
        XCTAssertEqual(cursor.endCalls, 1)
    }

    func testAreaCaptureMultiOverlayPresentationKeysExactlyOneWindow() throws {
        // Even when present(windows:) receives multiple overlays
        // (multi-screen layout), exactly one becomes key. Other windows
        // are ordered front via orderFrontRegardless to avoid focus theft.
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CursorSpy()
        guard let realScreen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("No screen attached (headless runner); multi-screen system test requires a display")
        }
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )
        let windows = (0..<3).map { _ in
            CaptureOverlayWindow(for: realScreen, cursorController: cursor)
        }

        coordinator.present(windows: windows)
        defer {
            coordinator.dismiss()
            windows.forEach { $0.close() }
            recorder.finishSession(session)
        }

        let keyOverlays = coordinator.overlayWindows.filter(\.isKeyWindow)
        XCTAssertEqual(
            keyOverlays.count, 1,
            "exactly one overlay must be key across a multi-screen layout"
        )
        XCTAssertEqual(coordinator.overlayWindows.count, 3)
        XCTAssertEqual(cursor.beginCalls, 1)
    }

    func testQuickAccessOverlayUsesCompactPanelWidth() {
        let image = TestImageFactory.makeTestImage(width: 120, height: 80)
        let screenshot = ProcessedScreenshot(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ),
            cgImage: image,
            context: CaptureContext(mode: .area)
        )

        QuickAccessOverlay.shared.show(for: screenshot)
        defer { QuickAccessOverlay.shared.dismiss() }

        guard let panel = QuickAccessOverlay.shared.debugPanel else {
            XCTFail("Expected quick access panel")
            return
        }
        XCTAssertLessThanOrEqual(panel.frame.width, 320)
        XCTAssertEqual(panel.contentView?.frame.height, 52)
    }

    func testPermissionRepairEntryShowsOnboardingWindow() {
        let suiteName = "CaptureSystemTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        let controller = OnboardingWindowController()

        controller.show(settings: settings)
        defer {
            controller.close()
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.windowTitle, "Welcome to Caloura")
    }
}

@MainActor
private final class CursorSpy: CaptureCursorControlling {
    private(set) var beginCalls = 0
    private(set) var reassertCalls = 0
    private(set) var endCalls = 0
    private(set) var resetCalls = 0
    private var activeSessionID: UInt?
    private var nextSessionID: UInt = 0

    func startCrosshairSession() -> any CaptureCursorSessionHandling {
        nextSessionID &+= 1
        activeSessionID = nextSessionID
        beginCalls += 1
        let sessionID = nextSessionID
        return CursorSessionSpy { [weak self] in
            guard let self, self.activeSessionID == sessionID else { return }
            self.activeSessionID = nil
            self.endCalls += 1
        }
    }

    func handleCursorUpdate() {
        reassertCalls += 1
    }

    func scheduleReprime() {
        reassertCalls += 1
    }

    func resetCursorState() {
        activeSessionID = nil
        resetCalls += 1
    }
}

@MainActor
private final class CursorSessionSpy: CaptureCursorSessionHandling {
    private let onEnd: @MainActor () -> Void
    private var didEnd = false

    init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
    }

    func end() {
        guard !didEnd else { return }
        didEnd = true
        onEnd()
    }
}

@MainActor
private func makeAreaOverlayWindows(
    cursorController: CaptureCursorControlling?
) -> [CaptureOverlayWindow] {
    CaptureOverlayWindow.orderedPresentationScreens().map {
        CaptureOverlayWindow(for: $0, cursorController: cursorController)
    }
}
