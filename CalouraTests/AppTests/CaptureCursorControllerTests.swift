import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureCursorControllerTests: XCTestCase {
    func testBeginCrosshairSessionActivatesAndSchedulesReassertion() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()

        XCTAssertEqual(driver.setCalls, 0)
        XCTAssertEqual(scheduler.scheduleCalls, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runPendingActions()

        XCTAssertEqual(driver.setCalls, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)

        controller.endCrosshairSession()
    }

    func testRepeatedBeginCrosshairSessionSchedulesOnce() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()
        controller.beginCrosshairSession()

        XCTAssertEqual(driver.setCalls, 0)
        XCTAssertEqual(scheduler.scheduleCalls, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runPendingActions()

        XCTAssertEqual(driver.setCalls, 1)

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

        XCTAssertEqual(driver.setCalls, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)

        controller.endCrosshairSession()
    }

    func testEndCrosshairSessionCancelsPendingReassertion() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.beginCrosshairSession()
        controller.endCrosshairSession()
        scheduler.runPendingActions()

        XCTAssertEqual(driver.setCalls, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.cancelledCount, 1)
    }

    func testReassertCrosshairNoOpWhenInactive() {
        let driver = CaptureCrosshairDriverSpy()
        let scheduler = CaptureCursorSchedulerSpy()
        let controller = CaptureCursorController(
            crosshairDriver: driver,
            scheduler: scheduler,
            notificationCenter: NotificationCenter()
        )

        controller.reassertCrosshair()

        XCTAssertEqual(driver.setCalls, 0)
    }
}

@MainActor
private final class CaptureCrosshairDriverSpy: CaptureCrosshairDriving {
    private(set) var setCalls = 0

    func setCrosshair() {
        setCalls += 1
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
