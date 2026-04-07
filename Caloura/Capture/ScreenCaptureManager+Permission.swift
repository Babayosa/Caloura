import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

extension ScreenCaptureManager {
    typealias MinimalScreenshotProbe = @Sendable (CGRect) async throws -> Void
    typealias DisplayBoundsProvider = @Sendable () -> CGRect
    typealias MinimalScreenshotCapture = @Sendable (
        CGRect,
        @escaping @Sendable (CGImage?, Error?) -> Void
    ) -> Void

    // MARK: - Permission

    enum PermissionState: Sendable {
        case neverGranted
        case grantedButFailing
    }

    /// Quick check using CoreGraphics — no prompt, but may not reflect
    /// SCK status on Sequoia.
    func checkPermission() -> Bool {
        let result = permissionDependencies.cgPreflight()
        logger.info("CGPreflightScreenCaptureAccess: \(result)")
        return result
    }

    /// Passive non-interactive permission check for lifecycle updates.
    func passivePermissionGranted() -> Bool {
        checkPermission()
    }

    /// Request screen recording permission via CoreGraphics.
    /// Only call from explicit user action.
    func requestPermission() -> Bool {
        permissionDependencies.cgRequest()
    }

    /// Quick single-attempt SCK check that uses a minimal screenshot probe.
    /// Background validation uses this without mutating `sckFailed`.
    func checkSCKAccess() async -> ScreenCaptureAccessProbeResult {
        await probeSCKAccess(updatingFailureState: true)
    }

    /// Explicit user-initiated SCK validation.
    /// Do not call passively on launch/activation.
    func validateSCKAccessUserInitiated() async -> ScreenCaptureAccessProbeResult {
        await probeSCKAccess(updatingFailureState: true)
    }

    /// Background validation for onboarding/launch. Never permanently
    /// disables SCK for later user-initiated capture.
    func primeSCKAccessIfPossible() async -> ScreenCaptureAccessProbeResult {
        await probeSCKAccess(updatingFailureState: false)
    }

    /// Restart replayd to clear stale SCK authorization cache.
    /// Returns true if SCK works after the restart.
    func repairSCKAccess() async -> ScreenCaptureAccessProbeResult {
        logger.info("Attempting replayd restart")
        do {
            try await permissionDependencies.runRepairTool(
                URL(filePath: "/bin/launchctl"),
                [
                    "kickstart", "-k",
                    "gui/\(getuid())/com.apple.replayd"
                ]
            )
        } catch {
            let desc = error.localizedDescription
            logger.warning("replayd restart failed: \(desc)")
            return .transientFailure
        }
        try? await Task.sleep(for: .milliseconds(500))
        return await probeSCKAccess(updatingFailureState: true)
    }

    /// Reset TCC entry so the system re-prompts on next request.
    func resetTCCEntry() async {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            logger.warning("Cannot reset TCC: bundle identifier unavailable")
            return
        }
        logger.info("Resetting TCC ScreenCapture entry for \(bundleID)")
        do {
            try await permissionDependencies.runRepairTool(
                URL(filePath: "/usr/bin/tccutil"),
                ["reset", "ScreenCapture", bundleID]
            )
        } catch {
            let desc = error.localizedDescription
            logger.warning("TCC reset failed: \(desc)")
        }
    }

    /// Relaunch the app cleanly via NSWorkspace.
    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        logger.info("Relaunching app from \(bundleURL.path)")
        Task { @MainActor in
            do {
                try await permissionDependencies.relaunchApplication(bundleURL)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.permissionDependencies.terminateApplication()
                }
            } catch {
                let description = error.localizedDescription
                logger.warning("Relaunch failed: \(description, privacy: .public)")
                permissionDependencies.statusMessageSink("Restart failed: \(description)")
            }
        }
    }

    /// Show a permission guidance alert for a specific diagnosed state.
    func showPermissionAlert(
        for state: PermissionState
    ) -> ScreenCapturePermissionAlertAction {

        let settingsURLString = "x-apple.systempreferences:"
            + "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        guard let settingsURL = URL(string: settingsURLString) else {
            return .cancel
        }

        switch state {
        case .neverGranted:
            let action = permissionDependencies.presentAlert(state)
            switch action {
            case .openSystemSettings:
                permissionDependencies.openURL(settingsURL)
            case .cancel, .restartApp:
                break
            }
            return action
        case .grantedButFailing:
            let action = permissionDependencies.presentAlert(state)
            switch action {
            case .restartApp:
                relaunchApp()
            case .openSystemSettings:
                permissionDependencies.openURL(settingsURL)
            case .cancel:
                break
            }
            return action
        }
    }

    private func probeSCKAccess(
        updatingFailureState: Bool
    ) async -> ScreenCaptureAccessProbeResult {
        let result = await permissionDependencies.sckAccessProbe()

        switch result {
        case .authorized:
            logger.info("SCK probe: authorized")
            setSCKFailed(false)
            sckFailureCount = 0
        case .userDeclined:
            logger.info("SCK probe: user declined")
            if updatingFailureState {
                setSCKFailed(true)
                logger.error("SCK permanently disabled (user declined)")
            }
        case .transientFailure:
            logger.info("SCK probe: transient failure")
            if updatingFailureState {
                sckFailureCount += 1
                if sckFailureCount >= maxTransientFailures {
                    setSCKFailed(true)
                    logger.warning(
                        "SCK disabled after \(self.maxTransientFailures) consecutive transient failures"
                    )
                }
            }
        }

        return result
    }

    nonisolated static func mainDisplayBounds() -> CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    nonisolated static func systemMinimalScreenshotCapture(
        in rect: CGRect,
        completion: @escaping @Sendable (CGImage?, Error?) -> Void
    ) {
        SCScreenshotManager.captureImage(in: rect, completionHandler: completion)
    }

    nonisolated static func defaultMinimalScreenshotProbe(
        _ rect: CGRect
    ) async throws {
        try await captureMinimalScreenshot(in: rect)
    }

    nonisolated static func probeSCKAccessViaMinimalScreenshot(
        displayBoundsProvider: DisplayBoundsProvider = mainDisplayBounds,
        screenshotProbe: @escaping MinimalScreenshotProbe = defaultMinimalScreenshotProbe
    ) async -> ScreenCaptureAccessProbeResult {
        let bounds = displayBoundsProvider()
        guard !bounds.isEmpty else {
            return .transientFailure
        }

        let probeRect = CGRect(
            x: bounds.origin.x + 1,
            y: bounds.origin.y + 1,
            width: min(2, max(1, bounds.width - 2)),
            height: min(2, max(1, bounds.height - 2))
        ).integral

        do {
            try await screenshotProbe(probeRect)
            return .authorized
        } catch {
            let nsError = error as NSError
            if nsError.domain == SCStreamError.errorDomain {
                let rawCode = nsError.code
                logger.info(
                    "SCK probe error: domain=\(nsError.domain) code=\(rawCode)"
                )
                if let code = SCStreamError.Code(rawValue: rawCode),
                   code == .userDeclined {
                    return .userDeclined
                }
            }
            return .transientFailure
        }
    }

    nonisolated static func captureMinimalScreenshot(
        in rect: CGRect,
        screenshotCapture: @escaping MinimalScreenshotCapture = systemMinimalScreenshotCapture(
            in:completion:
        )
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            screenshotCapture(rect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard image != nil else {
                    continuation.resume(
                        throwing: CaptureError.noContent(
                            source: "ScreenCaptureKit permission probe"
                        )
                    )
                    return
                }
                continuation.resume()
            }
        }
    }
}
