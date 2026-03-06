import AppKit

@MainActor
protocol CaptureCursorControlling: AnyObject {
    func beginCrosshairSession()
    func reassertCrosshair()
    func endCrosshairSession()
}

@MainActor
final class CaptureCursorController: NSObject, CaptureCursorControlling {
    private var cursorPushed = false
    private var watchdogTimer: Timer?
    private var watchdogRemainingTicks = 0

    func beginCrosshairSession() {
        guard !cursorPushed else {
            reassertCrosshair()
            restartWatchdog()
            return
        }

        NSCursor.crosshair.push()
        cursorPushed = true
        reassertCrosshair()
        restartWatchdog()
    }

    func reassertCrosshair() {
        NSCursor.crosshair.set()
    }

    func endCrosshairSession() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }

    private func restartWatchdog() {
        watchdogTimer?.invalidate()
        watchdogRemainingTicks = 4
        watchdogTimer = Timer.scheduledTimer(
            timeInterval: 0.075,
            target: self,
            selector: #selector(handleWatchdogTick(_:)),
            userInfo: nil,
            repeats: true
        )
        if let watchdogTimer {
            RunLoop.main.add(watchdogTimer, forMode: .common)
        }
    }

    @objc
    private func handleWatchdogTick(_ timer: Timer) {
        reassertCrosshair()
        watchdogRemainingTicks -= 1
        if watchdogRemainingTicks <= 0 {
            timer.invalidate()
            watchdogTimer = nil
        }
    }
}
