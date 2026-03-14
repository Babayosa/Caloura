import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureSessionCoordinatorTests: XCTestCase {
    func testAreaCoordinatorBeginsCrosshairBeforeOverlayPresentation() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .area)
        let cursor = CoordinatorCursorSpy()
        var beginCallsAtPresentation = 0
        var reassertCallsAtPresentation = 0
        var overlayVisibleCountAtPresentation: Int?

        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _, _, _ in },
            onCancel: { },
            overlayPresenter: { _, _, _, _, _ in
                beginCallsAtPresentation = cursor.beginCalls
                reassertCallsAtPresentation = cursor.reassertCalls
                overlayVisibleCountAtPresentation = recorder.summary(
                    for: .area,
                    event: .overlayVisible
                )?.sampleCount
                return []
            }
        )

        coordinator.present()
        coordinator.dismiss()
        recorder.finishSession(session)

        XCTAssertEqual(beginCallsAtPresentation, 1)
        XCTAssertEqual(reassertCallsAtPresentation, 0)
        XCTAssertNil(overlayVisibleCountAtPresentation)
        XCTAssertEqual(
            recorder.summary(for: .area, event: .overlayVisible)?.sampleCount,
            1
        )
        XCTAssertEqual(cursor.reassertCalls, 1)
        XCTAssertEqual(cursor.endCalls, 1)
        XCTAssertEqual(cursor.activeSessions, 0)
    }

    func testFullscreenCoordinatorBeginsCrosshairBeforeOverlayPresentation() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 10, reportInterval: 50)
        let session = recorder.beginSession(mode: .fullscreen)
        let cursor = CoordinatorCursorSpy()
        var beginCallsAtPresentation = 0
        var reassertCallsAtPresentation = 0
        var overlayVisibleCountAtPresentation: Int?

        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { _ in },
            onCancel: { },
            overlayPresenter: { _, _, _ in
                beginCallsAtPresentation = cursor.beginCalls
                reassertCallsAtPresentation = cursor.reassertCalls
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
        XCTAssertEqual(reassertCallsAtPresentation, 0)
        XCTAssertNil(overlayVisibleCountAtPresentation)
        XCTAssertEqual(
            recorder.summary(for: .fullscreen, event: .overlayVisible)?.sampleCount,
            1
        )
        XCTAssertEqual(cursor.reassertCalls, 1)
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
            onCancel: { },
            overlayPresenter: { _, _, _, _, _ in [] }
        )

        for _ in 0..<3 {
            coordinator.present()
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
        var presentedSelection: ((CGRect, NSScreen) -> Void)?

        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: recorder,
            cursorController: cursor,
            onSelection: { rect, screen, _ in
                capturedRegion = rect
                XCTAssertEqual(screen, expectedScreen)
                selectionExpectation.fulfill()
            },
            onCancel: { },
            overlayPresenter: { _, _, onRegionSelected, _, _ in
                presentedSelection = onRegionSelected
                return []
            }
        )

        coordinator.present()
        presentedSelection?(expectedRegion, expectedScreen)
        await fulfillment(of: [selectionExpectation], timeout: 1.0)
        recorder.finishSession(session)

        XCTAssertEqual(capturedRegion, expectedRegion)
        XCTAssertEqual(cursor.endCalls, 1)
        XCTAssertEqual(cursor.activeSessions, 0)
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
private final class CoordinatorCursorSpy: CaptureCursorControlling {
    private(set) var beginCalls = 0
    private(set) var reassertCalls = 0
    private(set) var endCalls = 0
    private(set) var activeSessions = 0
    private(set) var maxActiveSessions = 0

    func beginCrosshairSession() {
        beginCalls += 1
        activeSessions += 1
        maxActiveSessions = max(maxActiveSessions, activeSessions)
    }

    func reassertCrosshair() {
        reassertCalls += 1
    }

    func endCrosshairSession() {
        endCalls += 1
        activeSessions = max(0, activeSessions - 1)
    }
}
