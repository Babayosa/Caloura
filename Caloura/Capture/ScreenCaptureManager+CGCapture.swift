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
        let screenFrame = targetScreen.frame
        // Convert AppKit coords (bottom-left) to CG coords (top-left)
        let cgRect = CGRect(
            x: rect.origin.x,
            y: screenFrame.height - rect.origin.y - rect.height,
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

    // MARK: - CoreGraphics Window Enumeration
    // DEPRECATED: CGWindowListCopyWindowInfo is deprecated in macOS 15.
    // Remove when deployment target moves to 15.0+.

    /// Returns layer-0 (normal) window IDs in front-to-back z-order
    /// using CG metadata. No screen recording permission needed for
    /// metadata on Sequoia.
    func zOrderedWindowIDs() -> [CGWindowID] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return []
        }
        return windowList.compactMap { info in
            guard let layer = info[kCGWindowLayer] as? Int,
                  layer == 0 else { return nil }
            return info[kCGWindowNumber] as? CGWindowID
        }
    }

    func getWindowsCG() -> [CaptureWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return []
        }

        let bundleID = Bundle.main.bundleIdentifier
        var results: [CaptureWindow] = []

        for info in windowList {
            guard let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let ownerName = info[kCGWindowOwnerName] as? String,
                  let layer = info[kCGWindowLayer] as? Int,
                  layer == 0  // Normal window layer
            else { continue }

            // Skip our own app
            if let ownerPID = info[kCGWindowOwnerPID] as? pid_t {
                let runningApp = NSRunningApplication(
                    processIdentifier: ownerPID
                )
                if runningApp?.bundleIdentifier == bundleID {
                    continue
                }
            }

            let title = info[kCGWindowName] as? String ?? ""
            guard !title.isEmpty else { continue }

            // Extract window bounds
            guard let boundsDict = info[kCGWindowBounds]
                as? NSDictionary as CFDictionary?,
                let frame = CGRect(
                    dictionaryRepresentation: boundsDict
                ) else {
                continue
            }

            // Skip tiny utility windows and status items
            guard frame.width >= 50, frame.height >= 50 else {
                continue
            }

            let icon: NSImage? = (info[kCGWindowOwnerPID] as? pid_t)
                .flatMap {
                    NSRunningApplication(processIdentifier: $0)?.icon
                }

            results.append(CaptureWindow(
                id: windowID,
                title: title,
                appName: ownerName,
                frame: frame,
                scWindow: nil,
                appIcon: icon
            ))
        }

        return results
    }
}
