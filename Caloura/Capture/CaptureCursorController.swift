import AppKit

@MainActor
protocol CaptureCursorControlling: AnyObject {
    func beginCrosshairSession()
    func reassertCrosshair()
    func endCrosshairSession()
}

@MainActor
protocol CaptureCrosshairDriving {
    func pushCrosshair()
    func popCursor()
    func setCrosshair()
}

@MainActor
protocol CaptureCursorScheduledAction: AnyObject {
    func cancel()
}

@MainActor
protocol CaptureCursorScheduling {
    func schedule(_ action: @escaping @MainActor () -> Void) -> CaptureCursorScheduledAction
}

@MainActor
private struct SystemCaptureCrosshairDriver: CaptureCrosshairDriving {
    func pushCrosshair() {
        NSCursor.crosshair.push()
    }

    func popCursor() {
        NSCursor.pop()
    }

    func setCrosshair() {
        NSCursor.crosshair.set()
    }
}

@MainActor
private final class MainActorDeferredCaptureCursorAction: CaptureCursorScheduledAction {
    private var task: Task<Void, Never>?

    init(action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            action()
        }
    }

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
private struct MainActorCaptureCursorScheduler: CaptureCursorScheduling {
    func schedule(_ action: @escaping @MainActor () -> Void) -> CaptureCursorScheduledAction {
        MainActorDeferredCaptureCursorAction(action: action)
    }
}

@MainActor
final class CaptureCursorController: NSObject, CaptureCursorControlling {
    private let crosshairDriver: CaptureCrosshairDriving
    private let scheduler: CaptureCursorScheduling
    private let notificationCenter: NotificationCenter

    private var cursorPushed = false
    private var pendingReassertion: CaptureCursorScheduledAction?

    init(
        crosshairDriver: CaptureCrosshairDriving = SystemCaptureCrosshairDriver(),
        scheduler: CaptureCursorScheduling = MainActorCaptureCursorScheduler(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.crosshairDriver = crosshairDriver
        self.scheduler = scheduler
        self.notificationCenter = notificationCenter
        super.init()

        notificationCenter.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActiveNotification(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func beginCrosshairSession() {
        if !cursorPushed {
            crosshairDriver.pushCrosshair()
            cursorPushed = true
        }
        ensureReassertionScheduled()
    }

    func reassertCrosshair() {
        guard cursorPushed else { return }
        crosshairDriver.setCrosshair()
    }

    func endCrosshairSession() {
        pendingReassertion?.cancel()
        pendingReassertion = nil
        guard cursorPushed else { return }
        crosshairDriver.popCursor()
        cursorPushed = false
    }

    func handleApplicationDidBecomeActive() {
        ensureReassertionScheduled()
    }

    @objc
    private func handleApplicationDidBecomeActiveNotification(_ notification: Notification) {
        handleApplicationDidBecomeActive()
    }

    private func ensureReassertionScheduled() {
        guard cursorPushed, pendingReassertion == nil else { return }
        pendingReassertion = scheduler.schedule { [weak self] in
            guard let self = self else { return }
            self.pendingReassertion = nil
            self.reassertCrosshair()
        }
    }
}
