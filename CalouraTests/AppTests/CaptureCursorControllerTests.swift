import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureCursorControllerTests: XCTestCase {
    func testBeginCrosshairSessionPushesAndSchedulesReprime() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()

        XCTAssertEqual(driver.pushCalls, 1)
        XCTAssertEqual(scheduler.scheduleCalls, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runPendingActions()

        // Reprime pops then pushes
        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)

        controller.endCrosshairSession()
    }

    func testRepeatedBeginCrosshairSessionIsIdempotent() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()
        controller.beginCrosshairSession()

        XCTAssertEqual(driver.pushCalls, 1)
        XCTAssertEqual(scheduler.scheduleCalls, 1)

        controller.endCrosshairSession()
    }

    func testDidBecomeActiveDoesNotStarvePendingReprime() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()

        controller.handleApplicationDidBecomeActive()
        controller.handleApplicationDidBecomeActive()

        XCTAssertEqual(scheduler.scheduleCalls, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(scheduler.cancelledCount, 0)

        scheduler.runPendingActions()

        // Initial push + the original pending reprime. Repeated events must
        // not keep cancelling the action that reclaims the cursor from AppKit.
        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)

        controller.endCrosshairSession()
    }

    func testScheduleReprimeAfterPendingActionRunsSchedulesAgain() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()
        scheduler.runPendingActions()

        controller.scheduleReprime()

        XCTAssertEqual(scheduler.scheduleCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)

        controller.endCrosshairSession()
    }

    func testEndCrosshairSessionCancelsPendingAndPops() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()
        XCTAssertEqual(driver.pushCalls, 1)

        controller.endCrosshairSession()
        scheduler.runPendingActions()

        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.cancelledCount, 1)
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

        controller.beginCrosshairSession()
        controller.handleCursorUpdate()

        XCTAssertEqual(driver.setCalls, 1)

        controller.endCrosshairSession()
    }

    func testResetCursorStateClearsLeakedActiveSessionAndAllowsFreshBegin() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()
        XCTAssertEqual(driver.pushCalls, 1)
        XCTAssertEqual(scheduler.scheduleCalls, 1)

        // Simulate the bypass path: pool tearDown reached without
        // endCrosshairSession (e.g., screen reconfiguration).
        controller.resetCursorState()

        XCTAssertEqual(driver.popCalls, 1)
        XCTAssertEqual(scheduler.cancelledCount, 1)

        // The next begin must produce a fresh push, not silently no-op.
        // Without reset, the guard !cursorActive in beginCrosshairSession
        // would trap the controller in a permanently broken state.
        controller.beginCrosshairSession()
        XCTAssertEqual(driver.pushCalls, 2)
        XCTAssertEqual(scheduler.scheduleCalls, 2)

        controller.endCrosshairSession()
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

        controller.beginCrosshairSession()
        controller.endCrosshairSession()
        XCTAssertEqual(driver.popCalls, 1)

        controller.resetCursorState()

        // end already cleared pushed=false; reset must not pop again.
        XCTAssertEqual(driver.popCalls, 1)
    }
}

@MainActor
private final class CaptureCrosshairDriverSpy: CaptureCrosshairDriving {
    private(set) var setCalls = 0
    private(set) var pushCalls = 0
    private(set) var popCalls = 0

    func setCrosshair() {
        setCalls += 1
    }

    func pushCrosshair() {
        pushCalls += 1
    }

    func popCrosshair() {
        popCalls += 1
    }
}

@MainActor
private final class CaptureCursorSchedulerSpy: CaptureCursorScheduling {
    private final class ScheduledAction: CaptureCursorScheduledAction {
        private let action: @MainActor () -> Void
        private(set) var isCancelled = false
        private(set) var didRun = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }

        @MainActor
        func runIfNeeded() {
            guard !isCancelled, !didRun else { return }
            didRun = true
            action()
        }
    }

    private(set) var scheduleCalls = 0
    private var actions: [ScheduledAction] = []

    var pendingCount: Int {
        actions.filter { !$0.isCancelled && !$0.didRun }.count
    }

    var cancelledCount: Int {
        actions.filter(\.isCancelled).count
    }

    func schedule(_ action: @escaping @MainActor () -> Void) -> CaptureCursorScheduledAction {
        scheduleCalls += 1
        let scheduledAction = ScheduledAction(action: action)
        actions.append(scheduledAction)
        return scheduledAction
    }

    func runPendingActions() {
        for action in actions {
            action.runIfNeeded()
        }
    }
}
