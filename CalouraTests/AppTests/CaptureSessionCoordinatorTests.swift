import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureSessionCoordinatorTests: XCTestCase {
    func testAreaCoordinatorBeginsCrosshairBeforeOverlayPresentation() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CoordinatorCursorSpy()

        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )

        coordinator.present(windows: [])
        coordinator.dismiss()
        recorder.finishSession(session)

        XCTAssertEqual(cursor.beginCalls, 1)
        XCTAssertEqual(
            recorder.summary(for: .area, event: .overlayVisible)?.sampleCount,
            1
        )
        XCTAssertEqual(cursor.scheduleReprimeCalls, 1)
        XCTAssertEqual(cursor.endCalls, 1)
        XCTAssertEqual(cursor.activeSessions, 0)
    }

    func testAreaCoordinatorResetsAndBeginsBeforeOverlayWork() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CoordinatorCursorSpy()

        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )

        coordinator.present(windows: [])

        // Reset and begin must be the first two cursor events. Any later
        // primeCrosshair-driven scheduleReprime (from becomeKey) would be
        // a silent no-op if begin had not run first — that was the post-ship
        // crosshair regression.
        XCTAssertEqual(cursor.events.first, .reset)
        XCTAssertEqual(cursor.events.dropFirst().first, .begin)
        XCTAssertEqual(cursor.resetCalls, 1)

        coordinator.dismiss()
        recorder.finishSession(session)
    }

    func testFullscreenCoordinatorBeginsCrosshairBeforeOverlayPresentation() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CoordinatorCursorSpy()
        var beginCallsAtPresentation = 0
        var reprimeCallsAtPresentation = 0
        var overlayVisibleCountAtPresentation: Int?

        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _ in },
            onCancel: { },
            overlayPresenter: { _, _, _ in
                beginCallsAtPresentation = cursor.beginCalls
                reprimeCallsAtPresentation = cursor.scheduleReprimeCalls
                overlayVisibleCountAtPresentation = recorder.summary(
                    for: .fullscreen,
                    event: .overlayVisible
                )?.sampleCount
                return []
            }
        )

        coordinator.present()
        coordinator.dismiss()
        recorder.finishSession(session)

        XCTAssertEqual(beginCallsAtPresentation, 1)
        XCTAssertEqual(reprimeCallsAtPresentation, 0)
        XCTAssertNil(overlayVisibleCountAtPresentation)
        XCTAssertEqual(
            recorder.summary(for: .fullscreen, event: .overlayVisible)?.sampleCount,
            1
        )
        XCTAssertEqual(cursor.scheduleReprimeCalls, 1)
        XCTAssertEqual(cursor.endCalls, 1)
        XCTAssertEqual(cursor.activeSessions, 0)
    }

    func testAreaCoordinatorRepeatedPresentDismissBalancesCursorSessions() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CoordinatorCursorSpy()
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { }
        )

        for _ in 0..<3 {
            coordinator.present(windows: [])
            coordinator.dismiss()
        }
        recorder.finishSession(session)

        XCTAssertEqual(cursor.beginCalls, 3)
        XCTAssertEqual(cursor.endCalls, 3)
        XCTAssertEqual(cursor.activeSessions, 0)
        XCTAssertEqual(cursor.maxActiveSessions, 1)
    }

    func testAreaCoordinatorSelectionEndsCrosshairSession() async throws {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CoordinatorCursorSpy()
        let selectionExpectation = expectation(description: "selection callback")
        let expectedRegion = CGRect(x: 10, y: 12, width: 80, height: 60)
        let expectedScreen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        var capturedRegion: CGRect?

        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { rect, screen, _ in
                capturedRegion = rect
                XCTAssertEqual(screen, expectedScreen)
                selectionExpectation.fulfill()
            },
            onCancel: { }
        )

        let stubWindow = CaptureOverlayWindow(for: expectedScreen, cursorController: nil)
        coordinator.present(windows: [stubWindow])

        // Simulate selection via the window's callback
        stubWindow.onRegionSelected?(expectedRegion, expectedScreen)
        await fulfillment(of: [selectionExpectation], timeout: 1.0)
        recorder.finishSession(session)

        XCTAssertEqual(capturedRegion, expectedRegion)
        XCTAssertEqual(cursor.endCalls, 1)
        XCTAssertEqual(cursor.activeSessions, 0)
    }

    func testFullscreenCoordinatorDismissAfterScreenReconfigDoesNotLeakCursor() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CoordinatorCursorSpy()

        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _ in },
            onCancel: { },
            overlayPresenter: { _, _, _ in [] }
        )

        // First present → dismiss (e.g., screen reconfig teardown path).
        coordinator.present()
        coordinator.dismiss()

        // Second present must still reset+begin cleanly. If dismiss had leaked
        // state (no resetCursorState on re-entry, no centralized end path),
        // the second begin would trap the controller in a stuck state, same
        // shape as the D4 regression we shipped a fix for.
        coordinator.present()
        coordinator.dismiss()
        recorder.finishSession(session)

        XCTAssertEqual(cursor.beginCalls, 2)
        XCTAssertEqual(cursor.endCalls, 2)
        XCTAssertEqual(cursor.resetCalls, 2)
        XCTAssertEqual(cursor.activeSessions, 0)
        XCTAssertEqual(cursor.maxActiveSessions, 1)
    }

    func testFullscreenCoordinatorCancellationEndsCrosshairSession() async {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CoordinatorCursorSpy()
        let cancelExpectation = expectation(description: "cancel callback")
        var presentedCancel: (() -> Void)?

        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _ in },
            onCancel: {
                cancelExpectation.fulfill()
            },
            overlayPresenter: { _, _, onCancelled in
                presentedCancel = onCancelled
                return []
            }
        )

        coordinator.present()
        presentedCancel?()
        await fulfillment(of: [cancelExpectation], timeout: 1.0)
        recorder.finishSession(session)

        XCTAssertEqual(cursor.endCalls, 1)
        XCTAssertEqual(cursor.activeSessions, 0)
    }
}

@MainActor
final class CoordinatorCursorSpy: CaptureCursorControlling {
    enum Event: Equatable {
        case reset
        case begin
        case handleCursorUpdate
        case scheduleReprime
        case end
    }

    private(set) var beginCalls = 0
    private(set) var handleCursorUpdateCalls = 0
    private(set) var scheduleReprimeCalls = 0
    private(set) var endCalls = 0
    private(set) var resetCalls = 0
    private(set) var activeSessions = 0
    private(set) var maxActiveSessions = 0
    private(set) var events: [Event] = []

    func beginCrosshairSession() {
        beginCalls += 1
        activeSessions += 1
        maxActiveSessions = max(maxActiveSessions, activeSessions)
        events.append(.begin)
    }

    func handleCursorUpdate() {
        handleCursorUpdateCalls += 1
        events.append(.handleCursorUpdate)
    }

    func scheduleReprime() {
        scheduleReprimeCalls += 1
        events.append(.scheduleReprime)
    }

    func endCrosshairSession() {
        endCalls += 1
        activeSessions = max(0, activeSessions - 1)
        events.append(.end)
    }

    func resetCursorState() {
        resetCalls += 1
        activeSessions = 0
        events.append(.reset)
    }
}
