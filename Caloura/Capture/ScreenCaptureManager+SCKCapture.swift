import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

extension ScreenCaptureManager {

    // MARK: - SCK Capture

    func sckCaptureFullScreen(
        screen: NSScreen?
    ) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let targetScreen = screen
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }

        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let scDisplay = content.displays.first(where: { display in
            display.displayID == targetScreen
                .deviceDescription[screenKey] as? CGDirectDisplayID
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: scDisplay,
            excludingWindows: []
        )
        let config = SCStreamConfiguration()
        let scale = Int(targetScreen.backingScaleFactor)
        config.width = scDisplay.width * scale
        config.height = scDisplay.height * scale
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    func sckCaptureArea(
        rect: CGRect,
        screen: NSScreen?
    ) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let targetScreen = screen
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }

        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let scDisplay = content.displays.first(where: { display in
            display.displayID == targetScreen
                .deviceDescription[screenKey] as? CGDirectDisplayID
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: scDisplay,
            excludingWindows: []
        )
        let config = SCStreamConfiguration()

        // Convert from AppKit coordinates (bottom-left)
        // to ScreenCaptureKit (top-left)
        let screenFrame = targetScreen.frame
        let flippedY = screenFrame.height - rect.origin.y - rect.height

        let scale = targetScreen.backingScaleFactor
        config.sourceRect = CGRect(
            x: rect.origin.x,
            y: flippedY,
            width: rect.width,
            height: rect.height
        )
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    func sckCaptureWindow(
        _ window: SCWindow
    ) async throws -> CGImage {
        let filter = SCContentFilter(
            desktopIndependentWindow: window
        )
        let config = SCStreamConfiguration()
        config.width = Int(
            filter.contentRect.width
                * CGFloat(filter.pointPixelScale)
        )
        config.height = Int(
            filter.contentRect.height
                * CGFloat(filter.pointPixelScale)
        )
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    func sckGetWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.filter { window in
            guard let title = window.title,
                  !title.isEmpty else { return false }
            guard window.isOnScreen else { return false }
            // Exclude our own app
            return window.owningApplication?.bundleIdentifier
                != Bundle.main.bundleIdentifier
        }
    }
}
