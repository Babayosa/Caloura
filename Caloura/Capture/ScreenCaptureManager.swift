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
    func captureRectInDisplaySpace(rect: CGRect, screen: NSScreen?) throws -> CGRect
    func captureFrozenDisplaySnapshot(screen: NSScreen?) async throws -> CGImage
    func captureWindow(filter: SCContentFilter) async throws -> CGImage
    func captureAreaInDisplaySpace(_ rect: CGRect) async throws -> CGImage
}

protocol FrozenDisplaySnapshotOperation: AnyObject, Sendable {
    func captureImage() async throws -> CGImage
    func cancel() async
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
    /// Present the permission alert. Async so the live implementation can
    /// use `beginSheetModal` on an offscreen host window — this does NOT
    /// block the main run loop, unlike `runModal()` which greys the menu
    /// bar if the main thread is tied up long enough.
    let presentAlert: @MainActor @Sendable (
        ScreenCaptureManager.PermissionState
    ) async -> ScreenCapturePermissionAlertAction
    let openURL: @MainActor @Sendable (URL) -> Void
    let relaunchApplication: @MainActor @Sendable (URL) async throws -> Void
    let terminateApplication: @MainActor @Sendable () -> Void
    let statusMessageSink: @MainActor @Sendable (String) -> Void

    init(
        cgPreflight: @escaping @Sendable () -> Bool,
        cgRequest: @escaping @Sendable () -> Bool,
        sckAccessProbe: @escaping @Sendable () async -> ScreenCaptureAccessProbeResult,
        runRepairTool: @escaping @Sendable (URL, [String]) async throws -> Void,
        presentAlert: @escaping @MainActor @Sendable (ScreenCaptureManager.PermissionState) async -> ScreenCapturePermissionAlertAction,
        openURL: @escaping @MainActor @Sendable (URL) -> Void,
        relaunchApplication: @escaping @MainActor @Sendable (URL) async throws -> Void,
        terminateApplication: @escaping @MainActor @Sendable () -> Void,
        statusMessageSink: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.cgPreflight = cgPreflight
        self.cgRequest = cgRequest
        self.sckAccessProbe = sckAccessProbe
        self.runRepairTool = runRepairTool
        self.presentAlert = presentAlert
        self.openURL = openURL
        self.relaunchApplication = relaunchApplication
        self.terminateApplication = terminateApplication
        self.statusMessageSink = statusMessageSink ?? { message in
            StatusMessageRouter.sink(message)
        }
    }

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
            await ScreenCaptureManager.presentPermissionAlertNonBlocking(for: state)
        },
        openURL: { url in
            NSWorkspace.shared.open(url)
        },
        relaunchApplication: { bundleURL in
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
    private(set) var sckFailed: Bool = false

    /// Consecutive transient SCK failure count. After
    /// `maxTransientFailures` consecutive transient failures, `sckFailed`
    /// is set to `true` to avoid repeated slow fallback paths.
    var sckFailureCount: Int = 0

    /// Number of consecutive transient failures before giving up on SCK.
    let maxTransientFailures = 3

    /// Cached SCShareableContent to avoid 80–300ms fetch on every capture.
    /// TTL must be long enough that consecutive window captures (e.g. two
    /// Control+Option+W presses in the same minute) reuse the cache. The
    /// picker itself fetches fresh content when presented, so our cache is
    /// only a latency optimization for the prewarm step.
    private var cachedContent: SCShareableContent?
    private var cachedContentTimestamp: CFAbsoluteTime = 0
    private let contentCacheTTL: CFAbsoluteTime = 60.0

    /// Observer token for app-became-active notification.
    private var didBecomeActiveObserver: (any NSObjectProtocol)?
    let permissionDependencies: ScreenCapturePermissionDependencies
    private let shareableContentProvider: @MainActor () async throws -> SCShareableContent
    private let cgPreflightAuthorityProvider: @MainActor () -> Bool
    private let filteredScreenshotProvider: @MainActor (
        SCContentFilter,
        SCStreamConfiguration
    ) async throws -> CGImage
    private let makeFrozenDisplaySnapshotOperation: (
        SCContentFilter,
        SCStreamConfiguration,
        CGColorSpace?
    ) -> any FrozenDisplaySnapshotOperation

    /// Reset the SCK failure flag so that the next capture retries SCK.
    /// Called when permission is freshly granted or on a user-initiated
    /// reset. Wipes the shareable-content cache as well because permission
    /// changes can invalidate the filter list.
    func resetSCKState() {
        setSCKFailed(false)
        sckFailureCount = 0
        cachedContent = nil
        logger.info("SCK failure flag reset")
    }

    /// Lightweight reset used on routine app-become-active transitions (e.g.
    /// Cmd+Tab). Clears the transient-failure budget so the next capture
    /// retries SCK, but preserves the shareable-content cache — TTL handles
    /// genuine staleness (wake from sleep, hot-plug, long idle).
    private func refreshSCKFailureState() {
        setSCKFailed(false)
        sckFailureCount = 0
        logger.debug("SCK failure flag refreshed (cache preserved)")
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
        )? = nil,
        makeFrozenDisplaySnapshotOperation: ((
            SCContentFilter,
            SCStreamConfiguration,
            CGColorSpace?
        ) -> any FrozenDisplaySnapshotOperation)? = nil
    ) {
        self.permissionDependencies = permissionDependencies ?? .live
        self.shareableContentProvider = shareableContentProvider ?? {
            try await SCShareableContent.current
        }
        self.cgPreflightAuthorityProvider = cgPreflightAuthorityProvider ?? {
            PermissionCoordinator.shared.coreGraphicsPreflightIsAuthoritative()
        }
        self.filteredScreenshotProvider = filteredScreenshotProvider ?? { contentFilter, configuration in
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
                            throwing: CaptureError.noContent(
                                source: "ScreenCaptureKit screenshot"
                            )
                        )
                        return
                    }
                    continuation.resume(returning: image)
                }
            }
        }
        self.makeFrozenDisplaySnapshotOperation = (
            makeFrozenDisplaySnapshotOperation ?? { contentFilter, configuration, colorSpace in
                OneShotFrozenDisplayStreamCapture(
                    contentFilter: contentFilter,
                    configuration: configuration,
                    colorSpace: colorSpace
                )
            }
        )
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Cmd+Tab / return-from-background should not nuke the
                // shareable-content cache — the TTL already guards staleness.
                // Only refresh the transient-failure budget so the next
                // capture retries SCK cleanly, then warm in the background.
                self?.refreshSCKFailureState()
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

    enum ScreenCaptureFailureKind {
        case permissionDenied      // .userDeclined
        case systemStopped         // .systemStoppedStream — recoverable with retry
        case missingEntitlements   // .missingEntitlements — permanent, not transient
        case transient             // everything else
    }

    enum ScreenCaptureFailureContext {
        case captureOperation
        case freezeSnapshot
        case shareableContentLookup
    }

    func classifySCKError(_ error: Error) -> ScreenCaptureFailureKind {
        let nsError = error as NSError
        guard nsError.domain == SCStreamError.errorDomain,
              let code = SCStreamError.Code(rawValue: nsError.code) else {
            return .transient
        }
        switch code {
        case .userDeclined:
            return .permissionDenied
        case .systemStoppedStream:
            return .systemStopped
        case .missingEntitlements:
            return .missingEntitlements
        default:
            return .transient
        }
    }

    /// Record an SCK failure. Permanent errors disable SCK immediately.
    /// Transient errors increment a counter; after `maxTransientFailures`
    /// consecutive transient failures, SCK is disabled until reset.
    func handleSCKFailure(
        _ error: Error,
        context: ScreenCaptureFailureContext = .captureOperation
    ) {
        let kind = classifySCKError(error)
        switch kind {
        case .permissionDenied, .missingEntitlements:
            setSCKFailed(true)
            sckFailureCount = 0
            let label = kind == .permissionDenied ? "user declined" : "missing entitlements"
            logger.warning("SCK permanently disabled (\(label))")
        case .systemStopped:
            logger.info("SCK system stopped stream — will retry on next capture")
        case .transient:
            guard context == .captureOperation else {
                let desc = error.localizedDescription
                let contextLabel = String(describing: context)
                let logMessagePrefix = "SCK transient \(contextLabel) failure ignored for disable budget"
                logger.warning(
                    "\(logMessagePrefix, privacy: .public): \(desc, privacy: .public)"
                )
                return
            }
            sckFailureCount += 1
            let count = sckFailureCount
            logger.warning(
                "SCK transient failure \(count)/\(self.maxTransientFailures)"
            )
            if sckFailureCount >= maxTransientFailures {
                setSCKFailed(true)
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

    /// Only a real ScreenCaptureKit permission denial should map directly to
    /// `.noPermission` here. Today that means `SCStreamError.userDeclined`
    /// (raw value `-3801`). Other SCK failures are treated as transient unless
    /// CoreGraphics is currently authoritative and still denied.
    func shouldTreatCaptureErrorAsPermissionDenied(_ error: Error) -> Bool {
        let kind = classifySCKError(error)
        switch kind {
        case .permissionDenied:
            return true
        case .missingEntitlements:
            return false
        case .systemStopped:
            return false
        case .transient:
            return shouldTreatCoreGraphicsStateAsPermissionDenied()
        }
    }

    func captureErrorForSCKFailure(_ error: Error) -> CaptureError? {
        let kind = classifySCKError(error)
        switch kind {
        case .permissionDenied:
            return .noPermission
        case .missingEntitlements:
            return .configurationFailed(
                "ScreenCaptureKit is unavailable for this build"
            )
        case .systemStopped:
            return nil
        case .transient:
            if shouldTreatCoreGraphicsStateAsPermissionDenied() {
                return .noPermission
            }
            return nil
        }
    }

    // MARK: - SCShareableContent Cache

    func shareableContent(
        forceRefresh: Bool = false
    ) async throws -> SCShareableContent {
        let now = CFAbsoluteTimeGetCurrent()
        let liveScreenCount = NSScreen.screens.count
        if !forceRefresh,
           let cached = cachedContent,
           now - cachedContentTimestamp < contentCacheTTL,
           cached.displays.count == liveScreenCount {
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

    func captureFrozenDisplaySnapshot(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration,
        colorSpace: CGColorSpace? = nil
    ) async throws -> CGImage {
        let operation = makeFrozenDisplaySnapshotOperation(
            contentFilter,
            configuration,
            colorSpace
        )

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.captureImage()
        } onCancel: {
            Task { @MainActor in
                await operation.cancel()
            }
        }
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

    func setSCKFailed(_ failed: Bool) {
        sckFailed = failed
    }

    #if DEBUG
    func setSCKFailedForTesting(_ failed: Bool) {
        setSCKFailed(failed)
    }
    #endif

    // MARK: - Full Screen Capture

    /// Capture the full screen, falling back from SCK to CLI.
    func captureFullScreen(screen: NSScreen? = nil) async throws -> CGImage {
        try await withSCKFallback(
            label: "fullscreen",
            sckOperation: { try await self.sckCaptureFullScreen(screen: screen) },
            cliOperation: { try await self.screencaptureFullScreen(screen: screen) }
        )
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
            throw CaptureError.invalidRegion(reason: desc)
        }
        return try await withSCKFallback(
            label: "area",
            sckOperation: { try await self.sckCaptureArea(rect: rect, screen: screen) },
            cliOperation: { try await self.screencaptureArea(rect: rect, screen: screen) }
        )
    }

    func captureAreaInDisplaySpace(
        _ rect: CGRect
    ) async throws -> CGImage {
        guard rect.width > 0, rect.height > 0 else {
            let desc = rect.debugDescription
            logger.warning("Rejecting degenerate display-space rect: \(desc)")
            throw CaptureError.invalidRegion(reason: desc)
        }
        return try await withSCKFallback(
            label: "display-space area",
            sckOperation: { try await self.sckCaptureAreaInDisplaySpace(rect: rect) },
            cliOperation: { try await self.screencaptureAreaInDisplaySpace(rect: rect) }
        )
    }

    /// Run an SCK capture, falling back to the `screencapture` CLI when SCK
    /// fails transiently or has been disabled. Centralizes the error
    /// classification + permission-check rethrow that all three top-level
    /// capture entry points used to duplicate.
    private func withSCKFallback(
        label: String,
        sckOperation: () async throws -> CGImage,
        cliOperation: () async throws -> CGImage
    ) async throws -> CGImage {
        if !sckFailed {
            do {
                return try await sckOperation()
            } catch {
                logger.warning(
                    "SCK \(label, privacy: .public) failed: \(error.localizedDescription)"
                )
                handleSCKFailure(error)
                if let captureError = captureErrorForSCKFailure(error) {
                    throw captureError
                }
            }
        }
        do {
            logger.info("Trying screencapture CLI for \(label, privacy: .public)")
            return try await cliOperation()
        } catch {
            if sckFailed || shouldTreatCoreGraphicsStateAsPermissionDenied() {
                throw CaptureError.noPermission
            }
            throw error
        }
    }

    // MARK: - Window Capture

    /// Capture directly from an SCContentFilter (used by WindowPickerManager).
    /// This is the fastest path — no window lookup needed.
    func captureWindow(filter: SCContentFilter) async throws -> CGImage {
        do {
            return try await captureWindow(
                filter: filter,
                contentRect: filter.contentRect,
                pointPixelScale: CGFloat(filter.pointPixelScale)
            )
        } catch let error as CaptureError {
            if case .noContent = error {
                throw CaptureError.windowUnavailable(
                    reason: "Selected window capture produced no image content"
                )
            }
            throw error
        } catch {
            logger.warning(
                "SCK captureWindow failed: \(error.localizedDescription)"
            )
            handleSCKFailure(error)
            if let captureError = captureErrorForSCKFailure(error) {
                throw captureError
            }
            throw error
        }
    }

    func captureWindow(
        filter: SCContentFilter,
        contentRect: CGRect,
        pointPixelScale: CGFloat
    ) async throws -> CGImage {
        let config = try makeWindowCaptureConfiguration(
            contentRect: contentRect,
            pointPixelScale: pointPixelScale
        )
        return try await captureFilteredScreenshot(
            contentFilter: filter,
            configuration: config
        )
    }

    func makeWindowCaptureConfiguration(
        contentRect: CGRect,
        pointPixelScale: CGFloat
    ) throws -> SCStreamConfiguration {
        let reasonPrefix = "Selected window geometry became invalid: rect="
            + "\(contentRect.debugDescription) scale=\(pointPixelScale)"
        guard contentRect.origin.x.isFinite,
              contentRect.origin.y.isFinite,
              contentRect.width.isFinite,
              contentRect.height.isFinite,
              pointPixelScale.isFinite,
              pointPixelScale > 0,
              contentRect.width > 0,
              contentRect.height > 0 else {
            throw CaptureError.windowUnavailable(reason: reasonPrefix)
        }

        let config = SCStreamConfiguration()
        config.width = try safeWindowPixelDimension(
            contentRect.width * pointPixelScale,
            component: "width",
            reasonPrefix: reasonPrefix
        )
        config.height = try safeWindowPixelDimension(
            contentRect.height * pointPixelScale,
            component: "height",
            reasonPrefix: reasonPrefix
        )
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = true
        return config
    }

    private func safeWindowPixelDimension(
        _ value: CGFloat,
        component: String,
        reasonPrefix: String
    ) throws -> Int {
        guard value.isFinite, value > 0 else {
            throw CaptureError.windowUnavailable(
                reason: "\(reasonPrefix) invalid \(component)=\(value)"
            )
        }

        let rounded = ceil(value)
        guard rounded.isFinite, rounded > 0, rounded <= CGFloat(Int.max) else {
            throw CaptureError.windowUnavailable(
                reason: "\(reasonPrefix) out-of-range \(component)=\(rounded)"
            )
        }

        return Int(rounded)
    }

    // MARK: - Permission Alert Presentation

}

// MARK: - Errors

enum CaptureError: LocalizedError, Sendable {
    case noDisplay
    case noPermission
    case invalidRegion(reason: String)
    case timeout(operation: String)
    case noContent(source: String)
    case windowUnavailable(reason: String)
    case configurationFailed(String)
    case captureFailed(String)
    case cancelled

    var userMessage: String {
        switch self {
        case .noDisplay:
            return "No display is available for capture. "
                + "Connect a display and try again."
        case .noPermission:
            return "Screen recording permission is required. "
                + "Enable Caloura in System Settings > Privacy & Security "
                + "> Screen Recording, then try again."
        case .invalidRegion:
            return "The selected capture area is invalid. "
                + "Select a larger area and try again."
        case .timeout(let operation):
            return "\(operation) timed out. Try again. "
                + "If it keeps happening, restart Caloura."
        case .noContent(let source):
            return "\(source) did not produce an image. Try again."
        case .windowUnavailable:
            return "The selected window is no longer available. "
                + "Pick the window again and retry."
        case .configurationFailed:
            return "Screen capture is unavailable for this build. "
                + "Launch the signed Caloura app or reinstall it, then try again."
        case .captureFailed:
            return "Capture failed before an image was produced. Try again. "
                + "If it keeps happening, restart Caloura."
        case .cancelled:
            return "Capture was cancelled."
        }
    }

    var logMessage: String {
        switch self {
        case .noDisplay:
            return "No display found for capture"
        case .noPermission:
            return "Screen recording permission is required"
        case .invalidRegion(let reason):
            return "Invalid capture region: \(reason)"
        case .timeout(let operation):
            return "\(operation) timed out"
        case .noContent(let source):
            return "\(source) returned no image content"
        case .windowUnavailable(let reason):
            return reason
        case .configurationFailed(let reason):
            return reason
        case .captureFailed(let reason):
            return reason
        case .cancelled:
            return "Capture was cancelled"
        }
    }

    var errorDescription: String? {
        userMessage
    }
}
