import AppKit
import os.log

private let cursorLogger = Logger(subsystem: "com.caloura.app", category: "Cursor")

@MainActor
protocol CaptureCursorControlling: AnyObject {
    func startCrosshairSession() -> any CaptureCursorSessionHandling
    func handleCursorUpdate()
    func scheduleReprime()
    /// Force-clear any leaked cursor state from a prior session that did not
    /// reach its session token's `end()`. Safe to call when no session is active.
    /// Pool teardown calls this as a safety net.
    func resetCursorState()
}

@MainActor
protocol CaptureCursorSessionHandling: AnyObject {
    func end()
}

@MainActor
protocol CaptureCrosshairDriving {
    func setCaptureCursor()
    func pushCaptureCursor()
    func popCrosshair()
    func hideSystemCursor()
    func unhideSystemCursor()
}

@MainActor
protocol CaptureCursorScheduledAction: AnyObject {
    func cancel()
}

@MainActor
protocol CaptureCursorScheduling {
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> CaptureCursorScheduledAction
}

@MainActor
private struct SystemCaptureCrosshairDriver: CaptureCrosshairDriving {
    private static let transparentCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1)),
        hotSpot: .zero
    )

    func setCaptureCursor() {
        Self.transparentCursor.set()
    }

    func pushCaptureCursor() {
        Self.transparentCursor.push()
    }

    func popCrosshair() {
        NSCursor.pop()
    }

    func hideSystemCursor() {
        NSCursor.hide()
    }

    func unhideSystemCursor() {
        NSCursor.unhide()
    }
}

@MainActor
private final class MainActorDeferredCaptureCursorAction: CaptureCursorScheduledAction {
    private var task: Task<Void, Never>?

    init(delay: Duration, action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            // Sleep instead of yield: Task.yield() may resume before
            // AppKit finishes cursor rect processing from key-window
            // transitions. A minimal sleep ensures we fire after the
            // current run loop pass completes.
            try? await Task.sleep(for: delay)
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
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> CaptureCursorScheduledAction {
        MainActorDeferredCaptureCursorAction(delay: delay, action: action)
    }
}

@MainActor
final class CaptureCursorController: NSObject, CaptureCursorControlling {
    private static let initialReprimeDelay: Duration = .milliseconds(1)
    private static let maintenanceReprimeDelay: Duration = .milliseconds(50)

    private let crosshairDriver: CaptureCrosshairDriving
    private let scheduler: CaptureCursorScheduling
    private let notificationCenter: NotificationCenter

    private var cursorActive = false
    private var pushed = false
    private var systemCursorHidden = false
    private var pendingReprime: CaptureCursorScheduledAction?
    private var pendingMaintenanceReprime: CaptureCursorScheduledAction?
    private var activeSessionID: UInt?
    private var nextSessionID: UInt = 0

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

    func startCrosshairSession() -> any CaptureCursorSessionHandling {
        if cursorActive || pushed {
            resetCursorState()
        }
        nextSessionID &+= 1
        let sessionID = nextSessionID
        activeSessionID = sessionID
        cursorActive = true
        hideSystemCursorIfNeeded()
        if !pushed {
            crosshairDriver.pushCaptureCursor()
            pushed = true
        }
        cursorLogger.debug(
            "startCrosshairSession: id=\(sessionID, privacy: .public) pushed=true"
        )
        scheduleReprime()
        scheduleMaintenanceReprime()
        return CaptureCursorSession(controller: self, sessionID: sessionID)
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
        let scheduledSessionID = activeSessionID
        pendingReprime = scheduler.schedule(after: Self.initialReprimeDelay) { [weak self] in
            guard let self,
                  self.cursorActive,
                  self.activeSessionID == scheduledSessionID else {
                return
            }
            self.pendingReprime = nil
            self.reinstallCrosshair()
        }
    }

    private func scheduleMaintenanceReprime() {
        guard cursorActive else { return }
        guard pendingMaintenanceReprime == nil else { return }
        let scheduledSessionID = activeSessionID
        pendingMaintenanceReprime = scheduler.schedule(after: Self.maintenanceReprimeDelay) { [weak self] in
            guard let self,
                  self.cursorActive,
                  self.activeSessionID == scheduledSessionID else {
                return
            }
            self.pendingMaintenanceReprime = nil
            self.reinstallCrosshair()
            self.scheduleMaintenanceReprime()
        }
    }

    func endCrosshairSession(sessionID: UInt) {
        guard activeSessionID == sessionID else {
            cursorLogger.debug(
                "endCrosshairSession: stale token id=\(sessionID, privacy: .public)"
            )
            return
        }
        endActiveCrosshairSession()
    }

    private func endActiveCrosshairSession() {
        pendingReprime?.cancel()
        pendingReprime = nil
        pendingMaintenanceReprime?.cancel()
        pendingMaintenanceReprime = nil
        activeSessionID = nil
        cursorActive = false
        if pushed {
            crosshairDriver.popCrosshair()
            pushed = false
        }
        unhideSystemCursorIfNeeded()
        cursorLogger.debug("endCrosshairSession: cursorActive=false, pushed=false")
    }

    func resetCursorState() {
        let wasActive = cursorActive
        let wasPushed = pushed
        pendingReprime?.cancel()
        pendingReprime = nil
        pendingMaintenanceReprime?.cancel()
        pendingMaintenanceReprime = nil
        activeSessionID = nil
        cursorActive = false
        if pushed {
            crosshairDriver.popCrosshair()
            pushed = false
        }
        unhideSystemCursorIfNeeded()
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
        crosshairDriver.pushCaptureCursor()
        if wasPushed {
            crosshairDriver.popCrosshair()
        }
        pushed = true
        crosshairDriver.setCaptureCursor()
    }

    private func hideSystemCursorIfNeeded() {
        guard !systemCursorHidden else { return }
        crosshairDriver.hideSystemCursor()
        systemCursorHidden = true
    }

    private func unhideSystemCursorIfNeeded() {
        guard systemCursorHidden else { return }
        crosshairDriver.unhideSystemCursor()
        systemCursorHidden = false
    }
}

@MainActor
private final class CaptureCursorSession: CaptureCursorSessionHandling {
    private weak var controller: CaptureCursorController?
    private let sessionID: UInt
    private var didEnd = false

    init(controller: CaptureCursorController, sessionID: UInt) {
        self.controller = controller
        self.sessionID = sessionID
    }

    func end() {
        guard !didEnd else { return }
        didEnd = true
        controller?.endCrosshairSession(sessionID: sessionID)
    }
}
