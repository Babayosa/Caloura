import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureSystemTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            QuickAccessOverlay.shared.dismiss()
        }
    }

    override func tearDown() {
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

        coordinator.present()
        defer {
            coordinator.dismiss()
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
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: CursorSpy(),
            onSelection: { _, _, _ in },
            onCancel: { }
        )

        coordinator.present()
        defer {
            coordinator.dismiss()
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
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: CursorSpy(),
            onSelection: { _, _, _ in },
            onCancel: { }
        )

        coordinator.present()
        defer {
            coordinator.dismiss()
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
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .window)
        var presented = false
        var activationCount = 0
        let coordinator = WindowCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            hasWarmContent: false,
            activateApplication: {
                activationCount += 1
            },
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
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(
            recorder.summary(for: .window, event: .pickerVisibleCold) != nil
                || recorder.summary(for: .window, event: .pickerVisibleWarm) != nil
        )
    }

    func testPerformanceRecorder_generatesOverlaySamplesForStrictAudit() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 20, reportInterval: 50)

        for _ in 0..<5 {
            let areaSession = recorder.beginSession(mode: .area)
            let areaCoordinator = AreaCaptureSessionCoordinator(
                session: areaSession,
                performanceRecorder: recorder,
                cursorController: CursorSpy(),
                onSelection: { _, _, _ in },
                onCancel: { }
            )
            areaCoordinator.present()
            areaCoordinator.dismiss()
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
            await pipeline.performCapture(mode: .area, performanceSession: areaSession) { image }

            let fullscreenSession = recorder.beginSession(mode: .fullscreen)
            await pipeline.performCapture(
                mode: .fullscreen,
                performanceSession: fullscreenSession
            ) { image }

            let windowSession = recorder.beginSession(mode: .window)
            await pipeline.performCapture(mode: .window, performanceSession: windowSession) { image }
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

    func beginCrosshairSession() {
        beginCalls += 1
    }

    func reassertCrosshair() {
        reassertCalls += 1
    }

    func endCrosshairSession() {
        endCalls += 1
    }
}
