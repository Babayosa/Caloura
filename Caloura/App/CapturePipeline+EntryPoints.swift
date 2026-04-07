// MARK: - Capture Entry Points

extension CapturePipeline {

    func captureArea() {
        entrypointService.captureArea()
    }

    func captureFullscreen() {
        entrypointService.captureFullscreen()
    }

    func captureWindow() {
        entrypointService.captureWindow()
    }

    /// Re-capture the exact same region as the last area capture.
    func captureRepeat() {
        entrypointService.captureRepeat()
    }

    /// Capture with a countdown delay. Useful for capturing menus and tooltips.
    func captureDelayed(seconds: Int, mode: CaptureMode) {
        entrypointService.captureDelayed(seconds: seconds, mode: mode)
    }

    /// Cancel an in-progress delayed capture countdown.
    func cancelDelayedCapture() {
        entrypointService.cancelDelayedCapture()
    }
}
