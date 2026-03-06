import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

extension ScreenCaptureManager {

    // MARK: - SCK Capture

    func captureRectInDisplaySpace(
        rect: CGRect,
        screen: NSScreen?
    ) throws -> CGRect {
        let resolved = try resolveScreen(screen)
        let screenFrame = resolved.screen.frame
        let displayBounds = CGDisplayBounds(resolved.displayID)

        let globalY = displayBounds.origin.y
            + (screenFrame.height - rect.origin.y - rect.height)
        let globalX = displayBounds.origin.x + rect.origin.x

        return CGRect(
            x: globalX,
            y: globalY,
            width: rect.width,
            height: rect.height
        ).integral
    }

    func fullscreenRectInDisplaySpace(
        screen: NSScreen?
    ) throws -> CGRect {
        let resolved = try resolveScreen(screen)
        return CGDisplayBounds(resolved.displayID).integral
    }

    private func sckCaptureImage(
        in rect: CGRect
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(
                        throwing: CaptureError.captureFailed(
                            "ScreenCaptureKit returned no image"
                        )
                    )
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    func sckCaptureFullScreen(
        screen: NSScreen?
    ) async throws -> CGImage {
        let rect = try fullscreenRectInDisplaySpace(screen: screen)
        return try await sckCaptureImage(in: rect)
    }

    func sckCaptureArea(
        rect: CGRect,
        screen: NSScreen?
    ) async throws -> CGImage {
        let captureRect = try captureRectInDisplaySpace(
            rect: rect,
            screen: screen
        )
        return try await sckCaptureImage(in: captureRect)
    }

}
