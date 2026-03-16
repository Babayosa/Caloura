import AppKit

@MainActor
protocol CaptureCursorControlling: AnyObject {
    func beginCrosshairSession()
    func handleCursorUpdate()
    func scheduleReprime()
    func endCrosshairSession()
}

@MainActor
protocol CaptureCrosshairDriving {
    func setCrosshair()
    func pushCrosshair()
    func popCrosshair()
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
    func setCrosshair() {
        NSCursor.crosshair.set()
    }

    func pushCrosshair() {
        NSCursor.crosshair.push()
    }

    func popCrosshair() {
        NSCursor.pop()
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

    private var cursorActive = false
    private var pushed = false
    private var pendingReprime: CaptureCursorScheduledAction?

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
        notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceDidChangeNotification(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    func beginCrosshairSession() {
        guard !cursorActive else { return }
        cursorActive = true
        if !pushed {
            crosshairDriver.pushCrosshair()
            pushed = true
        }
        scheduleReprime()
    }

    func handleCursorUpdate() {
        guard cursorActive else { return }
        crosshairDriver.setCrosshair()
    }

    func scheduleReprime() {
        guard cursorActive, pendingReprime == nil else { return }
        pendingReprime = scheduler.schedule { [weak self] in
            guard let self, self.cursorActive else { return }
            self.pendingReprime = nil
            if self.pushed { self.crosshairDriver.popCrosshair() }
            self.crosshairDriver.pushCrosshair()
            self.pushed = true
        }
    }

    func endCrosshairSession() {
        pendingReprime?.cancel()
        pendingReprime = nil
        cursorActive = false
        if pushed {
            crosshairDriver.popCrosshair()
            pushed = false
        }
    }

    func handleApplicationDidBecomeActive() {
        scheduleReprime()
    }

    @objc
    private func handleApplicationDidBecomeActiveNotification(_ notification: Notification) {
        handleApplicationDidBecomeActive()
    }

    @objc
    private func handleSpaceDidChangeNotification(_ notification: Notification) {
        scheduleReprime()
    }
}
