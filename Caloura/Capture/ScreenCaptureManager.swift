@preconcurrency import AppKit
import os.log
@preconcurrency import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "ScreenCapture")

@MainActor
protocol ScreenCaptureManaging: AnyObject {
    var hasWarmWindowShareableContent: Bool { get }
    func prewarmWindowShareableContent() async
    func captureFullScreen(screen: NSScreen?) async throws -> CGImage
    func captureArea(rect: CGRect, screen: NSScreen?) async throws -> CGImage
    func captureFrozenDisplaySnapshot(screen: NSScreen?) async throws -> CGImage
    func captureWindow(filter: SCContentFilter) async throws -> CGImage
    func captureAreaInDisplaySpace(_ rect: CGRect) async throws -> CGImage
}

enum ScreenCapturePermissionAlertAction: Sendable {
    case cancel
    case openSystemSettings
    case restartApp
}

enum ScreenCaptureAccessProbeResult: Sendable, Equatable {
    case authorized
    case userDeclined
    case transientFailure
}

struct ScreenCapturePermissionDependencies: Sendable {
    let cgPreflight: @Sendable () -> Bool
    let cgRequest: @Sendable () -> Bool
    let sckAccessProbe: @Sendable () async -> ScreenCaptureAccessProbeResult
    let runRepairTool: @Sendable (URL, [String]) async throws -> Void
    let presentAlert: @MainActor @Sendable (
        ScreenCaptureManager.PermissionState
    ) -> ScreenCapturePermissionAlertAction
    let openURL: @MainActor @Sendable (URL) -> Void
    let relaunchApplication: @MainActor @Sendable (URL) async throws -> Void
    let terminateApplication: @MainActor @Sendable () -> Void

    @MainActor
    static let live = ScreenCapturePermissionDependencies(
        cgPreflight: {
            CGPreflightScreenCaptureAccess()
        },
        cgRequest: {
            CGRequestScreenCaptureAccess()
        },
        sckAccessProbe: {
            await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot()
        },
        runRepairTool: { executableURL, arguments in
            try await ScreenCaptureManager.runRepairTool(
                executableURL,
                arguments: arguments
            )
        },
        presentAlert: { state in
            let alert = NSAlert()
            alert.alertStyle = .warning
            NSApp.activate()

            switch state {
            case .neverGranted:
                alert.messageText = "Screen Recording Permission Required"
                alert.informativeText =
                    "Caloura needs screen recording access to capture "
                    + "screenshots.\n\n"
                    + "1. Click \"Open System Settings\" below\n"
                    + "2. Find Caloura in the list and toggle it ON\n"
                    + "3. You may need to quit and reopen Caloura "
                    + "after granting access"
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal() == .alertFirstButtonReturn
                    ? .openSystemSettings
                    : .cancel
            case .grantedButFailing:
                alert.messageText = "Screen Recording Permission Issue"
                alert.informativeText =
                    "Caloura has screen recording permission, but macOS "
                    + "is not allowing captures. This can happen after an "
                    + "app update or system change.\n\n"
                    + "Restarting Caloura usually fixes this. If not, try "
                    + "toggling the permission off and on in "
                    + "System Settings."
                alert.addButton(withTitle: "Restart Caloura")
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn:
                    return .restartApp
                case .alertSecondButtonReturn:
                    return .openSystemSettings
                default:
                    return .cancel
                }
            }
        },
        openURL: { url in
            NSWorkspace.shared.open(url)
        },
        relaunchApplication: { bundleURL in
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, Error>
            ) in
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: config
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    continuation.resume()
                }
            }
        },
        terminateApplication: {
            NSApp.terminate(nil)
        }
    )
}

@MainActor
final class ScreenCaptureManager: ScreenCaptureManaging {
    static let shared = ScreenCaptureManager()

    /// Once SCK fails permanently (e.g. user denied permission), skip it on
    /// subsequent captures to avoid repeated system prompts and latency.
    var sckFailed: Bool = false

    /// Consecutive transient SCK failure count. After
    /// `maxTransientFailures` consecutive transient failures, `sckFailed`
    /// is set to `true` to avoid repeated slow fallback paths.
    var sckFailureCount: Int = 0

    /// Number of consecutive transient failures before giving up on SCK.
    let maxTransientFailures = 3

    /// Cached SCShareableContent to avoid 80–300ms fetch on every capture.
    private var cachedContent: SCShareableContent?
    private var cachedContentTimestamp: CFAbsoluteTime = 0
    private let contentCacheTTL: CFAbsoluteTime = 2.0

    /// Observer token for app-became-active notification.
    private var didBecomeActiveObserver: (any NSObjectProtocol)?
    let permissionDependencies: ScreenCapturePermissionDependencies
    private let shareableContentProvider: @MainActor () async throws -> SCShareableContent
    private let cgPreflightAuthorityProvider: @MainActor () -> Bool
    private let filteredScreenshotProvider: @MainActor (
        SCContentFilter,
        SCStreamConfiguration
    ) async throws -> CGImage

    /// Reset the SCK failure flag so that the next capture retries SCK.
    /// Called when permission is freshly granted or on app reactivation.
    func resetSCKState() {
        sckFailed = false
        sckFailureCount = 0
        cachedContent = nil
        logger.info("SCK failure flag reset")
    }

    init(
        permissionDependencies: ScreenCapturePermissionDependencies? = nil,
        shareableContentProvider: (@MainActor () async throws -> SCShareableContent)? = nil,
        cgPreflightAuthorityProvider: (@MainActor () -> Bool)? = nil,
        filteredScreenshotProvider: (
            @MainActor (
                SCContentFilter,
                SCStreamConfiguration
            ) async throws -> CGImage
        )? = nil
    ) {
        self.permissionDependencies = permissionDependencies ?? .live
        self.shareableContentProvider = shareableContentProvider ?? {
            try await SCShareableContent.current
        }
        self.cgPreflightAuthorityProvider = cgPreflightAuthorityProvider ?? {
            PermissionCoordinator.shared.coreGraphicsPreflightIsAuthoritative()
        }
        self.filteredScreenshotProvider = filteredScreenshotProvider ?? {
            contentFilter,
            configuration in
            try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureImage(
                    contentFilter: contentFilter,
                    configuration: configuration
                ) { image, error in
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
    func isSCKErrorPermanent(_ error: Error) -> Bool {
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
    func handleSCKFailure(_ error: Error) {
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

    func shouldTreatCoreGraphicsStateAsPermissionDenied() -> Bool {
        guard cgPreflightAuthorityProvider() else {
            return false
        }
        return !checkPermission()
    }

    func shouldTreatCaptureErrorAsPermissionDenied(_ error: Error) -> Bool {
        if isSCKErrorPermanent(error) {
            return true
        }
        return shouldTreatCoreGraphicsStateAsPermissionDenied()
    }

    // MARK: - SCShareableContent Cache

    func shareableContent(
        forceRefresh: Bool = false
    ) async throws -> SCShareableContent {
        let now = CFAbsoluteTimeGetCurrent()
        if !forceRefresh,
           let cached = cachedContent,
           now - cachedContentTimestamp < contentCacheTTL {
            return cached
        }
        let content = try await shareableContentProvider()
        cachedContent = content
        cachedContentTimestamp = now
        return content
    }

    func captureFilteredScreenshot(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await filteredScreenshotProvider(contentFilter, configuration)
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
                if shouldTreatCaptureErrorAsPermissionDenied(error) {
                    throw CaptureError.noPermission
                }
            }
        }
        do {
            logger.info("Trying screencapture CLI for fullscreen")
            return try await screencaptureFullScreen(screen: screen)
        } catch {
            if shouldTreatCoreGraphicsStateAsPermissionDenied() {
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
                if shouldTreatCaptureErrorAsPermissionDenied(error) {
                    throw CaptureError.noPermission
                }
            }
        }

        do {
            logger.info("Trying screencapture CLI for area")
            return try await screencaptureArea(rect: rect, screen: screen)
        } catch {
            if shouldTreatCoreGraphicsStateAsPermissionDenied() {
                throw CaptureError.noPermission
            }
            throw error
        }
    }

    func captureAreaInDisplaySpace(
        _ rect: CGRect
    ) async throws -> CGImage {
        guard rect.width > 0, rect.height > 0 else {
            let desc = rect.debugDescription
            logger.warning("Rejecting degenerate display-space rect: \(desc)")
            throw CaptureError.captureFailed("Zero or negative size rect")
        }

        if !sckFailed {
            do {
                return try await sckCaptureAreaInDisplaySpace(rect: rect)
            } catch {
                logger.warning(
                    "SCK captureAreaInDisplaySpace failed: \(error.localizedDescription)"
                )
                handleSCKFailure(error)
                if shouldTreatCaptureErrorAsPermissionDenied(error) {
                    throw CaptureError.noPermission
                }
            }
        }

        do {
            logger.info("Trying screencapture CLI for display-space area")
            return try await screencaptureAreaInDisplaySpace(rect: rect)
        } catch {
            if shouldTreatCoreGraphicsStateAsPermissionDenied() {
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
            if shouldTreatCaptureErrorAsPermissionDenied(error) {
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
