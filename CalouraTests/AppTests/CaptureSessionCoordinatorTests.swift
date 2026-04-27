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

    func testAreaCoordinatorStartsCursorSessionBeforeOverlayWork() {
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

        // Cursor start must be the first cursor event. Any later
        // primeCrosshair-driven scheduleReprime (from becomeKey) would be
        // a silent no-op if start had not run first — that was the post-ship
        // crosshair regression.
        XCTAssertEqual(cursor.events.first, .begin)
        XCTAssertEqual(cursor.resetCalls, 0)

        coordinator.dismiss()
        recorder.finishSession(session)
    }

    func testFullscreenCoordinatorBeginsCrosshairBeforeOverlayPresentation() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CoordinatorCursorSpy()
        var beginCallsAtPresentation = 0
        var handleCallsAtPresentation = 0
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
                handleCallsAtPresentation = cursor.handleCursorUpdateCalls
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
        XCTAssertEqual(handleCallsAtPresentation, 0)
        XCTAssertEqual(reprimeCallsAtPresentation, 0)
        XCTAssertNil(overlayVisibleCountAtPresentation)
        XCTAssertEqual(
            recorder.summary(for: .fullscreen, event: .overlayVisible)?.sampleCount,
            1
        )
        XCTAssertEqual(cursor.handleCursorUpdateCalls, 1)
        XCTAssertEqual(cursor.scheduleReprimeCalls, 1)
        XCTAssertEqual(cursor.endCalls, 1)
        XCTAssertEqual(cursor.activeSessions, 0)
    }

    func testFullscreenCoordinatorReassertsCursorBeforeMarkingOverlayVisible() {
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

        coordinator.present()
        coordinator.dismiss()
        recorder.finishSession(session)

        XCTAssertEqual(
            Array(cursor.events.prefix(3)),
            [.begin, .handleCursorUpdate, .scheduleReprime]
        )
        XCTAssertEqual(cursor.handleCursorUpdateCalls, 1)
        XCTAssertEqual(cursor.scheduleReprimeCalls, 1)
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

    func testAreaSelectionThenSecondPresentationKeepsCursorSessionActive() async throws {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let driver = CoordinatorCrosshairDriverSpy()
        let scheduler = CoordinatorCursorSchedulerSpy()
        let cursorController = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )
        let pool = CaptureOverlayWindowPool()
        defer { pool.tearDown() }

        let firstSession = recorder.beginSession(mode: .area)
        let firstSelection = expectation(description: "first selection")
        let firstCoordinator = AreaCaptureSessionCoordinator(
            session: firstSession,
            performanceRecorder: recorder,
            cursorController: cursorController,
            onSelection: { _, _, _ in firstSelection.fulfill() },
            onCancel: { }
        )
        let firstWindows = pool.acquire(cursorController: cursorController)
        let firstWindow = try XCTUnwrap(firstWindows.first)
        let firstScreen = try XCTUnwrap(firstWindow.screen)

        firstCoordinator.present(windows: firstWindows)
        XCTAssertEqual(driver.pushCalls, driver.popCalls + 1)

        firstWindow.onRegionSelected?(
            CGRect(x: 10, y: 10, width: 80, height: 80),
            firstScreen
        )
        await fulfillment(of: [firstSelection], timeout: 1.0)
        pool.release()
        recorder.finishSession(firstSession)
        XCTAssertEqual(driver.pushCalls, driver.popCalls)

        let secondSession = recorder.beginSession(mode: .area)
        let secondCoordinator = AreaCaptureSessionCoordinator(
            session: secondSession,
            performanceRecorder: recorder,
            cursorController: cursorController,
            onSelection: { _, _, _ in },
            onCancel: { }
        )
        let secondWindows = pool.acquire(cursorController: cursorController)
        secondCoordinator.present(windows: secondWindows)

        XCTAssertEqual(driver.pushCalls, driver.popCalls + 1)
        XCTAssertFalse(secondCoordinator.overlayWindows.isEmpty)

        secondCoordinator.dismiss()
        pool.release()
        recorder.finishSession(secondSession)
        XCTAssertEqual(driver.pushCalls, driver.popCalls)
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

        // Second present must still start cleanly. If dismiss had leaked state,
        // the second start would trap the controller in a stuck state, same
        // shape as the D4 regression we shipped a fix for.
        coordinator.present()
        coordinator.dismiss()
        recorder.finishSession(session)

        XCTAssertEqual(cursor.beginCalls, 2)
        XCTAssertEqual(cursor.endCalls, 2)
        XCTAssertEqual(cursor.resetCalls, 0)
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

    func startCrosshairSession() -> any CaptureCursorSessionHandling {
        beginCalls += 1
        activeSessions += 1
        maxActiveSessions = max(maxActiveSessions, activeSessions)
        events.append(.begin)
        return CoordinatorCursorSessionSpy { [weak self] in
            guard let self else { return }
            self.endCalls += 1
            self.activeSessions = max(0, self.activeSessions - 1)
            self.events.append(.end)
        }
    }

    func handleCursorUpdate() {
        handleCursorUpdateCalls += 1
        events.append(.handleCursorUpdate)
    }

    func scheduleReprime() {
        scheduleReprimeCalls += 1
        events.append(.scheduleReprime)
    }

    func resetCursorState() {
        resetCalls += 1
        activeSessions = 0
        events.append(.reset)
    }
}

@MainActor
private final class CoordinatorCursorSessionSpy: CaptureCursorSessionHandling {
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
private final class CoordinatorCrosshairDriverSpy: CaptureCrosshairDriving {
    private(set) var pushCalls = 0
    private(set) var popCalls = 0

    func setCrosshair() {}

    func pushCrosshair() {
        pushCalls += 1
    }

    func popCrosshair() {
        popCalls += 1
    }
}

@MainActor
private final class CoordinatorCursorSchedulerSpy: CaptureCursorScheduling {
    func schedule(_ action: @escaping @MainActor () -> Void) -> CaptureCursorScheduledAction {
        CoordinatorCursorScheduledActionSpy()
    }
}

@MainActor
private final class CoordinatorCursorScheduledActionSpy: CaptureCursorScheduledAction {
    func cancel() {}
}
