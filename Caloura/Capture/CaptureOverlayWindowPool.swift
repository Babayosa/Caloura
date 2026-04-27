import AppKit

@MainActor
final class CaptureOverlayWindowPool {
    private var windows: [CaptureOverlayWindow] = []
    private var screenFrames: [CGRect] = []
    private weak var lastCursorController: CaptureCursorControlling?
    private let screensProvider: @MainActor () -> [NSScreen]

    init(
        screensProvider: @escaping @MainActor () -> [NSScreen] = {
            CaptureOverlayWindow.orderedPresentationScreens()
        }
    ) {
        self.screensProvider = screensProvider
    }

    func acquire(cursorController: CaptureCursorControlling?) -> [CaptureOverlayWindow] {
        let screens = screensProvider()
        let currentFrames = screens.map(\.frame)
        lastCursorController = cursorController

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
        // Safety net: coordinator paths normally end their cursor session on
        // the controller, but bypass paths (screen reconfig teardown, abnormal
        // unwind) reach the pool directly. resetCursorState is idempotent.
        lastCursorController?.resetCursorState()
        for window in windows {
            window.orderOut(nil)
            window.tearDownHandlers()
        }
    }

    func tearDown() {
        lastCursorController?.resetCursorState()
        for window in windows { window.close() }
        windows = []
        screenFrames = []
    }
}
