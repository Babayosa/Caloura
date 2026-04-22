import AppKit

@MainActor
final class CaptureSessionState {
    let overlayWindowPool: CaptureOverlayWindowPool
    /// Shared across area and fullscreen coordinators. Safe because `beginCaptureIfIdle`
    /// prevents concurrent capture sessions.
    let cursorController: CaptureCursorControlling = CaptureCursorController()

    init(overlayWindowPool: CaptureOverlayWindowPool = CaptureOverlayWindowPool()) {
        self.overlayWindowPool = overlayWindowPool
    }
    var overlayWindows: [CaptureOverlayWindow] = []
    var screenOverlays: [ScreenSelectionOverlayWindow] = []
    var areaCaptureSession: (any AreaCaptureSessionHandling)?
    var fullscreenCaptureSession: (any FullscreenCaptureSessionHandling)?
    var delayedCaptureTask: Task<Void, Never>?

    private(set) var captureSessionID: UInt = 0
    private(set) var firstMouseDownLogged = false

    func beginTrackedSession() -> UInt {
        captureSessionID &+= 1
        firstMouseDownLogged = false
        return captureSessionID
    }

    func isCurrentTrackedSession(_ sessionID: UInt) -> Bool {
        captureSessionID == sessionID
    }

    func recordFirstMouseDownIfNeeded() -> Bool {
        guard !firstMouseDownLogged else { return false }
        firstMouseDownLogged = true
        return true
    }

    func replaceDelayedCaptureTask(_ task: Task<Void, Never>?) {
        delayedCaptureTask?.cancel()
        delayedCaptureTask = task
    }

    func clearDelayedCaptureTask() {
        delayedCaptureTask = nil
    }
}
