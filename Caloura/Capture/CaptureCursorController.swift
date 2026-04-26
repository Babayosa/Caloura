import AppKit
import os.log

private let cursorLogger = Logger(subsystem: "com.caloura.app", category: "Cursor")

@MainActor
protocol CaptureCursorControlling: AnyObject {
    func beginCrosshairSession()
    func handleCursorUpdate()
    func scheduleReprime()
    func endCrosshairSession()
    /// Force-clear any leaked cursor state from a prior session that did not
    /// reach `endCrosshairSession()`. Safe to call when no session is active.
    /// Pool teardown and coordinator entry call this as a safety net.
    func resetCursorState()
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
            // Sleep instead of yield: Task.yield() may resume before
            // AppKit finishes cursor rect processing from key-window
            // transitions. A minimal sleep ensures we fire after the
            // current run loop pass completes.
            try? await Task.sleep(for: .milliseconds(1))
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
        guard !cursorActive else {
            cursorLogger.debug("beginCrosshairSession: already active, no-op (idempotent)")
            return
        }
        cursorActive = true
        if !pushed {
            crosshairDriver.pushCrosshair()
            pushed = true
        }
        cursorLogger.debug("beginCrosshairSession: pushed=true, cursorActive=true")
        scheduleReprime()
    }

    func handleCursorUpdate() {
        guard cursorActive else {
            cursorLogger.debug("handleCursorUpdate: cursorActive=false, dropping cursor update")
            return
        }
        reinstallCrosshair()
    }

    func scheduleReprime() {
        guard cursorActive else {
            cursorLogger.debug("scheduleReprime: cursorActive=false, dropping reprime")
            return
        }
        guard pendingReprime == nil else { return }
        pendingReprime = scheduler.schedule { [weak self] in
            guard let self, self.cursorActive else { return }
            self.pendingReprime = nil
            self.reinstallCrosshair()
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
        cursorLogger.debug("endCrosshairSession: cursorActive=false, pushed=false")
    }

    func resetCursorState() {
        let wasActive = cursorActive
        let wasPushed = pushed
        pendingReprime?.cancel()
        pendingReprime = nil
        cursorActive = false
        if pushed {
            crosshairDriver.popCrosshair()
            pushed = false
        }
        if wasActive || wasPushed {
            cursorLogger.error(
                "resetCursorState leaked: active=\(wasActive, privacy: .public) pushed=\(wasPushed, privacy: .public)"
            )
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

    private func reinstallCrosshair() {
        // Push new crosshair BEFORE popping the old one so there is never a
        // frame in which the cursor stack reverts to the arrow.
        let wasPushed = pushed
        crosshairDriver.pushCrosshair()
        if wasPushed {
            crosshairDriver.popCrosshair()
        }
        pushed = true
        crosshairDriver.setCrosshair()
    }
}
