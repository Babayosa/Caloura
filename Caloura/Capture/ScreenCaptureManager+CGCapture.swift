import AppKit
import os.log

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

// MARK: - CoreGraphics Fallback Capture
// Note: In debug builds with ad-hoc signing, CG capture may only
// include the desktop and Caloura's own windows. Other apps' windows
// require effective screen recording permission tied to a stable
// code signature.
//
// DEPRECATED: CGWindowListCreateImage is deprecated in macOS 15
// (Sequoia). These CG fallback methods are retained for graceful
// degradation on macOS 14 but should be removed when the deployment
// target moves to 15.0+.
// Prefer ScreenCaptureKit (SCK) for all capture operations.

extension ScreenCaptureManager {

    func cgCaptureFullScreen(screen: NSScreen?) throws -> CGImage {
        guard let targetScreen = screen
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = targetScreen
            .deviceDescription[screenKey] as? CGDirectDisplayID else {
            throw CaptureError.noDisplay
        }
        let displayBounds = CGDisplayBounds(displayID)
        guard let image = CGWindowListCreateImage(
            displayBounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else {
            throw CaptureError.captureFailed(
                "CGWindowListCreateImage returned nil for display"
            )
        }
        return image
    }

    func cgCaptureArea(
        rect: CGRect,
        screen: NSScreen?
    ) throws -> CGImage {
        guard let targetScreen = screen
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = targetScreen
            .deviceDescription[screenKey] as? CGDirectDisplayID else {
            throw CaptureError.noDisplay
        }
        let screenFrame = targetScreen.frame
        let displayBounds = CGDisplayBounds(displayID)

        // Convert AppKit local coords (bottom-left origin)
        // to global CG coords (top-left origin)
        let localCGY = screenFrame.height
            - rect.origin.y - rect.height
        let cgRect = CGRect(
            x: displayBounds.origin.x + rect.origin.x,
            y: displayBounds.origin.y + localCGY,
            width: rect.width,
            height: rect.height
        )
        guard let image = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else {
            throw CaptureError.captureFailed(
                "CGWindowListCreateImage returned nil"
            )
        }
        return image
    }

    func cgCaptureWindow(windowID: CGWindowID) throws -> CGImage {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            throw CaptureError.captureFailed(
                "CGWindowListCreateImage returned nil "
                + "for window \(windowID)"
            )
        }
        return image
    }

}
