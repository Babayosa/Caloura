import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

extension ScreenCaptureManager {

    // MARK: - SCK Capture

    private struct FrozenDisplayCaptureTarget {
        let resolvedScreen: ResolvedScreen
        let display: SCDisplay
        let excludedApplications: [SCRunningApplication]
    }

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

    private func freezeCaptureTarget(
        screen: NSScreen?,
        shareableContent: SCShareableContent
    ) throws -> FrozenDisplayCaptureTarget {
        let resolvedScreen = try resolveScreen(screen)
        guard let display = shareableContent.displays.first(where: {
            $0.displayID == resolvedScreen.displayID
        }) else {
            throw CaptureError.captureFailed(
                "Failed to resolve shareable display for freeze snapshot"
            )
        }

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw CaptureError.captureFailed(
                "Failed to resolve the current app bundle identifier"
            )
        }

        guard let currentApplication = shareableContent.applications.first(where: {
            $0.processID == getpid() || $0.bundleIdentifier == bundleIdentifier
        }) else {
            throw CaptureError.captureFailed(
                "Failed to resolve Caloura in shareable applications"
            )
        }

        return FrozenDisplayCaptureTarget(
            resolvedScreen: resolvedScreen,
            display: display,
            excludedApplications: [currentApplication]
        )
    }

    private func makeFreezeSnapshotConfiguration(
        for screen: NSScreen
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(
            1,
            Int(screen.frame.width * screen.backingScaleFactor)
        )
        configuration.height = max(
            1,
            Int(screen.frame.height * screen.backingScaleFactor)
        )
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.shouldBeOpaque = true
        return configuration
    }

    func sckCaptureFullScreen(
        screen: NSScreen?
    ) async throws -> CGImage {
        let rect = try fullscreenRectInDisplaySpace(screen: screen)
        return try await sckCaptureImage(in: rect)
    }

    func captureFrozenDisplaySnapshot(
        screen: NSScreen? = nil
    ) async throws -> CGImage {
        guard !sckFailed else {
            throw CaptureError.captureFailed(
                "Freeze snapshot unavailable while ScreenCaptureKit is disabled"
            )
        }

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await self.shareableContent()
        } catch {
            handleSCKFailure(error)
            if shouldTreatCaptureErrorAsPermissionDenied(error) {
                throw CaptureError.noPermission
            }
            throw error
        }

        let target: FrozenDisplayCaptureTarget
        do {
            target = try freezeCaptureTarget(
                screen: screen,
                shareableContent: shareableContent
            )
        } catch {
            let refreshedContent: SCShareableContent
            do {
                refreshedContent = try await self.shareableContent(forceRefresh: true)
            } catch {
                handleSCKFailure(error)
                if shouldTreatCaptureErrorAsPermissionDenied(error) {
                    throw CaptureError.noPermission
                }
                throw error
            }
            target = try freezeCaptureTarget(
                screen: screen,
                shareableContent: refreshedContent
            )
        }

        let filter = SCContentFilter(
            display: target.display,
            excludingApplications: target.excludedApplications,
            exceptingWindows: []
        )
        let configuration = makeFreezeSnapshotConfiguration(
            for: target.resolvedScreen.screen
        )

        do {
            return try await captureFilteredScreenshot(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            logger.warning(
                "SCK captureFrozenDisplaySnapshot failed: \(error.localizedDescription)"
            )
            handleSCKFailure(error)
            if shouldTreatCaptureErrorAsPermissionDenied(error) {
                throw CaptureError.noPermission
            }
            throw error
        }
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

    func sckCaptureAreaInDisplaySpace(
        rect: CGRect
    ) async throws -> CGImage {
        try await sckCaptureImage(in: rect.integral)
    }

}
