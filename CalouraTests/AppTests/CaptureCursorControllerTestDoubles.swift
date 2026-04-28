import Foundation
@testable import Caloura

@MainActor
final class CaptureCrosshairDriverSpy: CaptureCrosshairDriving {
    enum Event: Equatable {
        case set
        case push
        case pop
        case hide
        case unhide
    }

    private(set) var setCalls = 0
    private(set) var pushCalls = 0
    private(set) var popCalls = 0
    private(set) var hideCalls = 0
    private(set) var unhideCalls = 0
    private(set) var events: [Event] = []

    func setCrosshair() {
        setCalls += 1
        events.append(.set)
    }

    func pushCrosshair() {
        pushCalls += 1
        events.append(.push)
    }

    func popCrosshair() {
        popCalls += 1
        events.append(.pop)
    }

    func hideSystemCursor() {
        hideCalls += 1
        events.append(.hide)
    }

    func unhideSystemCursor() {
        unhideCalls += 1
        events.append(.unhide)
    }
}

@MainActor
final class CaptureCursorSchedulerSpy: CaptureCursorScheduling {
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

    private(set) var delays: [Duration] = []

    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> CaptureCursorScheduledAction {
        scheduleCalls += 1
        delays.append(delay)
        let scheduledAction = ScheduledAction(action: action)
        actions.append(scheduledAction)
        return scheduledAction
    }

    func runPendingActions(limit: Int? = nil) {
        var remaining = limit
        for action in actions where remaining.map({ $0 > 0 }) ?? true {
            action.runIfNeeded()
            remaining = remaining.map { $0 - 1 }
        }
    }
}
