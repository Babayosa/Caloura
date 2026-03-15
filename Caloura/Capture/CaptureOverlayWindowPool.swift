import AppKit

@MainActor
final class CaptureOverlayWindowPool {
    private var windows: [CaptureOverlayWindow] = []
    private var screenFrames: [CGRect] = []

    func acquire(cursorController: CaptureCursorControlling?) -> [CaptureOverlayWindow] {
        let screens = CaptureOverlayWindow.orderedPresentationScreens()
        let currentFrames = screens.map(\.frame)

        if currentFrames != screenFrames || windows.count != screens.count {
            tearDown()
            windows = screens.map { CaptureOverlayWindow(for: $0, cursorController: cursorController) }
            screenFrames = currentFrames
        } else {
            for window in windows {
                window.resetForReuse(cursorController: cursorController)
            }
        }
        return windows
    }

    func release() {
        for window in windows {
            window.orderOut(nil)
            window.tearDownHandlers()
        }
    }

    func tearDown() {
        for window in windows { window.close() }
        windows = []
        screenFrames = []
    }
}
