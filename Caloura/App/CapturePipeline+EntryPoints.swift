import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")
// MARK: - Capture Entry Points

extension CapturePipeline {

    // MARK: Perform Captures

    func performAreaCapture(
        rect: CGRect,
        screen: NSScreen?,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await performCapture(mode: .area, performanceSession: performanceSession) {
            try await self.captureManager.captureArea(
                rect: rect, screen: screen
            )
        }
    }

    /// Crop from an already-captured frozen image (for freeze capture mode)
    func performFrozenAreaCapture(
        rect: CGRect,
        screen: NSScreen,
        frozenImage: CGImage,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await performCapture(mode: .area, performanceSession: performanceSession) {
            // Convert screen coordinates to image coordinates
            let scale = screen.backingScaleFactor
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - rect.origin.y - rect.height

            // Calculate crop rect relative to this screen's image
            let imageRect = CGRect(
                x: rect.origin.x * scale,
                y: flippedY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral

            guard let croppedImage = frozenImage.cropping(to: imageRect) else {
                throw CaptureError.captureFailed(
                    "Failed to crop frozen image"
                )
            }
            return croppedImage
        }
    }

    func performFullscreenCapture(
        screen: NSScreen? = nil,
        dismissDelay: Bool = false,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        if dismissDelay {
            // Brief delay to let menu bar close / overlays dismiss
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        await performCapture(
            mode: .fullscreen,
            performanceSession: performanceSession
        ) {
            try await self.captureManager.captureFullScreen(screen: screen)
        }
    }

    func performWindowCapture(
        capture: @escaping @MainActor () async throws -> CGImage,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await performCapture(mode: .window, performanceSession: performanceSession) {
            try await capture()
        }
    }

    // MARK: Entry Points

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
