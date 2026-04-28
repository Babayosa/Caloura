import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureCursorControllerTests: XCTestCase {
    func testStartCrosshairSessionPushesAndSchedulesReprime() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()

        XCTAssertEqual(driver.hideCalls, 1)
        XCTAssertEqual(driver.pushCalls, 1)
        XCTAssertEqual(scheduler.scheduleCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 2)
        XCTAssertEqual(scheduler.delays, [.milliseconds(1), .milliseconds(50)])

        scheduler.runPendingActions(limit: 1)

        // Reprime reinstalls the crosshair without an arrow gap.
        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(driver.events, [.hide, .pushCaptureCursor, .pushCaptureCursor, .pop, .set])
        XCTAssertEqual(scheduler.pendingCount, 1)

        session.end()
        XCTAssertEqual(driver.unhideCalls, 1)
    }

    func testRepeatedStartCrosshairSessionResetsLeakedActiveSession() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let firstSession = controller.startCrosshairSession()
        let secondSession = controller.startCrosshairSession()

        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.hideCalls, 2)
        XCTAssertEqual(driver.unhideCalls, 1)
        XCTAssertEqual(scheduler.scheduleCalls, 4)
        XCTAssertEqual(scheduler.cancelledCount, 2)

        firstSession.end()
        XCTAssertEqual(driver.popCalls, 1)

        secondSession.end()
        XCTAssertEqual(driver.popCalls, 2)
        XCTAssertEqual(driver.unhideCalls, 2)
    }

    func testDidBecomeActiveDoesNotStarvePendingReprime() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()

        controller.handleApplicationDidBecomeActive()
        controller.handleApplicationDidBecomeActive()

        XCTAssertEqual(scheduler.scheduleCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 2)
        XCTAssertEqual(scheduler.cancelledCount, 0)

        scheduler.runPendingActions(limit: 1)

        // Initial push + the original pending reprime. Repeated events must
        // not keep cancelling the action that reclaims the cursor from AppKit.
        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)

        session.end()
    }

    func testScheduleReprimeAfterPendingActionRunsSchedulesAgain() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()
        scheduler.runPendingActions(limit: 1)

        controller.scheduleReprime()

        XCTAssertEqual(scheduler.scheduleCalls, 3)
        XCTAssertEqual(scheduler.pendingCount, 2)

        session.end()
    }

    func testMaintenanceReprimeKeepsCrosshairOwnedUntilSessionEnds() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()

        scheduler.runPendingActions(limit: 2)

        XCTAssertEqual(
            driver.events,
            [
                .hide,
                .pushCaptureCursor,
                .pushCaptureCursor,
                .pop,
                .set,
                .pushCaptureCursor,
                .pop,
                .set
            ]
        )
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(scheduler.scheduleCalls, 3)
        XCTAssertEqual(scheduler.delays, [.milliseconds(1), .milliseconds(50), .milliseconds(50)])

        session.end()
        scheduler.runPendingActions()

        XCTAssertEqual(driver.pushCalls, driver.popCalls)
        XCTAssertEqual(driver.hideCalls, driver.unhideCalls)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testEndCrosshairSessionCancelsPendingAndPops() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()
        XCTAssertEqual(driver.pushCalls, 1)

        session.end()
        scheduler.runPendingActions()

        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.unhideCalls, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.cancelledCount, 2)
    }

    func testHandleCursorUpdateNoOpWhenInactive() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.handleCursorUpdate()

        XCTAssertEqual(driver.setCalls, 0)
    }

    func testHandleCursorUpdateSetsWhenActive() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()
        controller.handleCursorUpdate()

        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.setCalls, 1)
        XCTAssertEqual(driver.events, [.hide, .pushCaptureCursor, .pushCaptureCursor, .pop, .set])

        session.end()
    }

    func testRepeatedCursorUpdatesKeepCrosshairOwnershipBalanced() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()
        controller.handleCursorUpdate()
        controller.handleCursorUpdate()
        controller.handleCursorUpdate()

        XCTAssertEqual(driver.pushCalls, 4)
        XCTAssertEqual(driver.popCalls, 3)
        XCTAssertEqual(driver.setCalls, 3)

        session.end()

        XCTAssertEqual(driver.popCalls, 4)
    }

    func testResetCursorStateClearsLeakedActiveSessionAndAllowsFreshBegin() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let leakedSession = controller.startCrosshairSession()
        XCTAssertEqual(driver.pushCalls, 1)
        XCTAssertEqual(scheduler.scheduleCalls, 2)

        // Simulate the bypass path: pool tearDown reached without
        // the cursor session token's end (e.g., screen reconfiguration).
        controller.resetCursorState()

        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.unhideCalls, 1)
        XCTAssertEqual(scheduler.cancelledCount, 2)

        // The next start must produce a fresh push, not silently no-op.
        // Without reset, cursorActive would trap the controller in a
        // permanently broken state.
        let freshSession = controller.startCrosshairSession()
        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(driver.hideCalls, 2)
        XCTAssertEqual(scheduler.scheduleCalls, 4)

        leakedSession.end()
        XCTAssertEqual(driver.popCalls, 1)

        freshSession.end()
    }

    func testResetCursorStateOnInactiveControllerIsSafeNoOp() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.resetCursorState()
        controller.resetCursorState()

        XCTAssertEqual(driver.pushCalls, 0)
        XCTAssertEqual(driver.popCalls, 0)
        XCTAssertEqual(driver.hideCalls, 0)
        XCTAssertEqual(driver.unhideCalls, 0)
        XCTAssertEqual(scheduler.scheduleCalls, 0)
    }

    func testResetCursorStateAfterEndDoesNotDoublePop() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()
        session.end()
        XCTAssertEqual(driver.popCalls, 1)

        controller.resetCursorState()

        // end already cleared pushed=false; reset must not pop again.
        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.unhideCalls, 1)
    }

    func testSessionTokenEndIsExactOnce() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        let session = controller.startCrosshairSession()
        session.end()
        session.end()

        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.unhideCalls, 1)
    }

    func testRepeatedSessionsBalanceNativeCursorHideAndUnhide() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        for _ in 0..<10 {
            let session = controller.startCrosshairSession()
            scheduler.runPendingActions(limit: 1)
            session.end()
        }

        XCTAssertEqual(driver.hideCalls, 10)
        XCTAssertEqual(driver.unhideCalls, 10)
        XCTAssertEqual(driver.pushCalls, driver.popCalls)
    }
}
