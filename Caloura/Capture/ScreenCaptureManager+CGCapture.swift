import AppKit
import os.log

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

// MARK: - CoreGraphics Fallback Capture (Stubbed)
// CGWindowListCreateImage was removed in macOS 26.
// These stubs preserve the method signatures so callers compile,
// but always throw — SCK and CLI are the active capture paths.

extension ScreenCaptureManager {

    func cgCaptureFullScreen(screen: NSScreen?) throws -> CGImage {
        logger.warning("CG fallback unavailable on macOS 26+")
        throw CaptureError.captureFailed(
            "CGWindowListCreateImage is unavailable on macOS 26"
        )
    }

    func cgCaptureArea(
        rect: CGRect,
        screen: NSScreen?
    ) throws -> CGImage {
        logger.warning("CG fallback unavailable on macOS 26+")
        throw CaptureError.captureFailed(
            "CGWindowListCreateImage is unavailable on macOS 26"
        )
    }

    func cgCaptureWindow(windowID: CGWindowID) throws -> CGImage {
        logger.warning("CG fallback unavailable on macOS 26+")
        throw CaptureError.captureFailed(
            "CGWindowListCreateImage is unavailable on macOS 26"
        )
    }

}
