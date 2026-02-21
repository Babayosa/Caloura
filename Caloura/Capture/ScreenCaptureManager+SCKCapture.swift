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
        let resolved = try resolveScreen(screen)
        let content = try await SCShareableContent.current

        guard let scDisplay = content.displays.first(where: { display in
            display.displayID == resolved.displayID
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: scDisplay,
            excludingWindows: []
        )
        let config = SCStreamConfiguration()
        let scale = resolved.screen.backingScaleFactor
        config.width = Int(CGFloat(scDisplay.width) * scale)
        config.height = Int(CGFloat(scDisplay.height) * scale)
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
        let resolved = try resolveScreen(screen)
        let content = try await SCShareableContent.current

        guard let scDisplay = content.displays.first(where: { display in
            display.displayID == resolved.displayID
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
        let screenFrame = resolved.screen.frame
        let flippedY = screenFrame.height - rect.origin.y - rect.height

        let scale = resolved.screen.backingScaleFactor
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

}
