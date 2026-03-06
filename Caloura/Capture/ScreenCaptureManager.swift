@preconcurrency import AppKit
import os.log
@preconcurrency import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "ScreenCapture")

@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    /// Once SCK fails permanently (e.g. user denied permission), skip it on
    /// subsequent captures to avoid repeated system prompts and latency.
    var sckFailed: Bool = false

    /// Consecutive transient SCK failure count. After
    /// `maxTransientFailures` consecutive transient failures, `sckFailed`
    /// is set to `true` to avoid repeated slow fallback paths.
    private var sckFailureCount: Int = 0

    /// Number of consecutive transient failures before giving up on SCK.
    private let maxTransientFailures = 3

    /// Cached SCShareableContent to avoid 80–300ms fetch on every capture.
    private var cachedContent: SCShareableContent?
    private var cachedContentTimestamp: CFAbsoluteTime = 0
    private let contentCacheTTL: CFAbsoluteTime = 2.0

    /// Observer token for app-became-active notification.
    private var didBecomeActiveObserver: (any NSObjectProtocol)?

    /// Reset the SCK failure flag so that the next capture retries SCK.
    /// Called when permission is freshly granted or on app reactivation.
    func resetSCKState() {
        sckFailed = false
        sckFailureCount = 0
        cachedContent = nil
        logger.info("SCK failure flag reset")
    }

    init() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetSCKState()
                await self?.prewarmWindowShareableContent()
            }
        }
    }

    deinit {
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Screen Resolution

    struct ResolvedScreen {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
    }

    func resolveScreen(_ preferred: NSScreen?) throws -> ResolvedScreen {
        guard let screen = preferred ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID ?? CGMainDisplayID()
        return ResolvedScreen(screen: screen, displayID: displayID)
    }

    // MARK: - SCK Error Classification

    /// Returns `true` for errors that indicate a permanent SCK failure
    /// (e.g. user denied screen recording permission). Transient errors
    /// (timeouts, resource contention, unknown) return `false`.
    private func isSCKErrorPermanent(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SCStreamError.errorDomain else {
            return false
        }
        if let code = SCStreamError.Code(rawValue: nsError.code) {
            return code == .userDeclined
        }
        return false
    }

    /// Record an SCK failure. Permanent errors disable SCK immediately.
    /// Transient errors increment a counter; after `maxTransientFailures`
    /// consecutive transient failures, SCK is disabled until reset.
    private func handleSCKFailure(_ error: Error) {
        if isSCKErrorPermanent(error) {
            sckFailed = true
            sckFailureCount = 0
            logger.warning("SCK permanently disabled (user declined)")
        } else {
            sckFailureCount += 1
            let count = sckFailureCount
            logger.warning(
                "SCK transient failure \(count)/\(self.maxTransientFailures)"
            )
            if sckFailureCount >= maxTransientFailures {
                sckFailed = true
                let desc = error.localizedDescription
                logger.warning(
                    "SCK disabled after \(count) transient failures: \(desc)"
                )
            }
        }
    }

    // MARK: - SCShareableContent Cache

    func shareableContent() async throws -> SCShareableContent {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedContent,
           now - cachedContentTimestamp < contentCacheTTL {
            return cached
        }
        let content = try await SCShareableContent.current
        cachedContent = content
        cachedContentTimestamp = now
        return content
    }

    var hasWarmWindowShareableContent: Bool {
        guard cachedContent != nil else { return false }
        return CFAbsoluteTimeGetCurrent() - cachedContentTimestamp < contentCacheTTL
    }

    func prewarmWindowShareableContent() async {
        guard checkPermission(), !sckFailed else { return }
        do {
            _ = try await shareableContent()
        } catch {
            logger.debug(
                "Window shareable content prewarm skipped: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Full Screen Capture

    /// Capture the full screen, falling back from SCK to CLI.
    func captureFullScreen(screen: NSScreen? = nil) async throws -> CGImage {
        if !sckFailed {
            do {
                return try await sckCaptureFullScreen(screen: screen)
            } catch {
                logger.warning(
                    "SCK captureFullScreen failed: \(error.localizedDescription)"
                )
                handleSCKFailure(error)
            }
        }
        do {
            logger.info("Trying screencapture CLI for fullscreen")
            return try await screencaptureFullScreen(screen: screen)
        } catch {
            if !checkPermission() {
                throw CaptureError.noPermission
            }
            throw error
        }
    }

    // MARK: - Area Capture

    /// Capture a rectangular region of the screen, falling back from SCK to CLI.
    func captureArea(
        rect: CGRect,
        screen: NSScreen? = nil
    ) async throws -> CGImage {
        guard rect.width > 0, rect.height > 0 else {
            let desc = rect.debugDescription
            logger.warning("Rejecting degenerate capture rect: \(desc)")
            throw CaptureError.captureFailed("Zero or negative size rect")
        }

        if !sckFailed {
            do {
                return try await sckCaptureArea(rect: rect, screen: screen)
            } catch {
                logger.warning(
                    "SCK captureArea failed: \(error.localizedDescription)"
                )
                handleSCKFailure(error)
            }
        }

        do {
            logger.info("Trying screencapture CLI for area")
            return try await screencaptureArea(rect: rect, screen: screen)
        } catch {
            if !checkPermission() {
                throw CaptureError.noPermission
            }
            throw error
        }
    }

    // MARK: - Window Capture

    /// Capture directly from an SCContentFilter (used by WindowPickerManager).
    /// This is the fastest path — no window lookup needed.
    func captureWindow(filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = Int(
            filter.contentRect.width * CGFloat(filter.pointPixelScale)
        )
        config.height = Int(
            filter.contentRect.height * CGFloat(filter.pointPixelScale)
        )
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = true

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            logger.warning(
                "SCK captureWindow failed: \(error.localizedDescription)"
            )
            handleSCKFailure(error)
            if isSCKErrorPermanent(error) || !checkPermission() {
                throw CaptureError.noPermission
            }
            throw error
        }
    }

}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case noDisplay
    case noPermission
    case captureFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display found for capture."
        case .noPermission:
            return "Screen recording permission is required. "
                + "Please enable it in System Settings "
                + "> Privacy & Security > Screen Recording."
        case .captureFailed(let reason):
            return "Capture failed: \(reason)"
        case .cancelled:
            return "Capture was cancelled."
        }
    }
}
