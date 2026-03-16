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

    func testDidBecomeActiveSchedulesOneBoundedReprime() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()
        scheduler.runPendingActions()

        controller.handleApplicationDidBecomeActive()
        controller.handleApplicationDidBecomeActive()

        XCTAssertEqual(scheduler.scheduleCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runPendingActions()

        // Initial push + begin reprime + didBecomeActive reprime
        XCTAssertEqual(driver.pushCalls, 3)
        XCTAssertEqual(scheduler.pendingCount, 0)

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
