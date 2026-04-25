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
        // Asks for explicit user consent before the coordinator runs
        // `tccutil reset ScreenCapture` and relaunches the app.
        case confirmRepairRelaunch
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
    func resetTCCEntry() async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            logger.warning("Cannot reset TCC: bundle identifier unavailable")
            return false
        }
        logger.info("Resetting TCC ScreenCapture entry for \(bundleID)")
        do {
            try await permissionDependencies.runRepairTool(
                URL(filePath: "/usr/bin/tccutil"),
                ["reset", "ScreenCapture", bundleID]
            )
            return true
        } catch {
            let desc = error.localizedDescription
            logger.warning("TCC reset failed: \(desc)")
            return false
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
    ) async -> ScreenCapturePermissionAlertAction {

        let settingsURLString = "x-apple.systempreferences:"
            + "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        guard let settingsURL = URL(string: settingsURLString) else {
            return .cancel
        }

        switch state {
        case .neverGranted:
            let action = await permissionDependencies.presentAlert(state)
            switch action {
            case .openSystemSettings:
                permissionDependencies.openURL(settingsURL)
            case .cancel, .restartApp:
                break
            }
            return action
        case .grantedButFailing:
            let action = await permissionDependencies.presentAlert(state)
            switch action {
            case .restartApp:
                relaunchApp()
            case .openSystemSettings:
                permissionDependencies.openURL(settingsURL)
            case .cancel:
                break
            }
            return action
        case .confirmRepairRelaunch:
            // The coordinator drives the reset+relaunch on approval; this
            // method is only responsible for surfacing the alert.
            return await permissionDependencies.presentAlert(state)
        }
    }

    private func probeSCKAccess(
        updatingFailureState: Bool
    ) async -> ScreenCaptureAccessProbeResult {
        let result = await permissionDependencies.sckAccessProbe()

        switch result {
        case .authorized:
            logger.info("SCK probe: authorized")
            setSCKFailed(false, reason: nil)
            sckFailureCount = 0
        case .userDeclined:
            logger.info("SCK probe: user declined")
            if updatingFailureState {
                setSCKFailed(true, reason: .permissionDenied)
                logger.error("SCK permanently disabled (user declined)")
            }
        case .configurationFailure:
            logger.error("SCK probe: configuration failure")
            if updatingFailureState {
                setSCKFailed(true, reason: .missingEntitlements)
            }
        case .transientFailure:
            logger.info("SCK probe: transient failure")
            if updatingFailureState {
                sckFailureCount += 1
                if sckFailureCount >= maxTransientFailures {
                    setSCKFailed(true, reason: .transientFailures)
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
                } else if let code = SCStreamError.Code(rawValue: rawCode),
                          code == .missingEntitlements {
                    return .configurationFailure
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

// MARK: - Permission Alert

extension ScreenCaptureManager {
    /// Build the NSAlert for a permission state. Pure factory — no AppKit
    /// side effects (no activation, no run loop mutation), so tests can
    /// assert title/buttons without presenting the alert.
    @MainActor
    static func makePermissionAlert(for state: PermissionState) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
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
        case .confirmRepairRelaunch:
            alert.messageText = "Reset Screen Recording permission?"
            alert.informativeText =
                "Caloura can't verify its Screen Recording access. "
                + "Resetting the permission and relaunching usually "
                + "fixes this, but you'll need to re-approve Caloura "
                + "in System Settings afterward.\n\n"
                + "Reset only if a plain restart didn't work."
            alert.addButton(withTitle: "Reset and Relaunch")
            alert.addButton(withTitle: "Cancel")
        }
        return alert
    }

    /// Map an NSAlert modal response code to the coordinator action.
    /// Pure — safe for unit tests without AppKit side effects.
    nonisolated static func mapAlertResponse(
        _ response: NSApplication.ModalResponse,
        for state: PermissionState
    ) -> ScreenCapturePermissionAlertAction {
        switch state {
        case .neverGranted:
            return response == .alertFirstButtonReturn ? .openSystemSettings : .cancel
        case .grantedButFailing:
            switch response {
            case .alertFirstButtonReturn:
                return .restartApp
            case .alertSecondButtonReturn:
                return .openSystemSettings
            default:
                return .cancel
            }
        case .confirmRepairRelaunch:
            return response == .alertFirstButtonReturn ? .restartApp : .cancel
        }
    }

    /// Present the permission alert without blocking the awaiter. The modal
    /// runs on the next run-loop tick so the calling async task yields
    /// before the nested event loop begins. We deliberately skip
    /// `NSApp.activate()` here — Caloura is a menu bar app, and forcing
    /// activation during a capture flow steals focus from whatever app
    /// the user was in, producing the "menu bar greys for a minute"
    /// symptom reported during post-overhaul manual testing.
    @MainActor
    static func presentPermissionAlertNonBlocking(
        for state: PermissionState
    ) async -> ScreenCapturePermissionAlertAction {
        typealias Continuation = CheckedContinuation<
            ScreenCapturePermissionAlertAction, Never
        >
        return await withCheckedContinuation { (continuation: Continuation) in
            DispatchQueue.main.async {
                let alert = Self.makePermissionAlert(for: state)
                let response = alert.runModal()
                let action = Self.mapAlertResponse(response, for: state)
                continuation.resume(returning: action)
            }
        }
    }
}
