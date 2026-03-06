import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

extension ScreenCaptureManager {

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

    /// Quick single-attempt SCK check for passive status updates
    /// (e.g. app launch). Does not retry or show alerts — just checks
    /// on success. Also sets `sckFailed` so subsequent captures skip
    /// SCK entirely.
    func checkSCKAccess() async -> Bool {
        do {
            let counts = try await permissionDependencies.sckAccessProbe()
            let displayCount = counts.displayCount
            let windowCount = counts.windowCount
            logger.info(
                "SCK check: authorized (\(displayCount) displays, \(windowCount) windows)"
            )
            sckFailed = false
            return true
        } catch {
            let desc = error.localizedDescription
            logger.info(
                "SCK check: not authorized (\(desc))"
            )
            sckFailed = true
            return false
        }
    }

    /// Explicit user-initiated SCK validation.
    /// Do not call passively on launch/activation.
    func validateSCKAccessUserInitiated() async -> Bool {
        await checkSCKAccess()
    }

    /// Restart replayd to clear stale SCK authorization cache.
    /// Returns true if SCK works after the restart.
    func repairSCKAccess() async -> Bool {
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
            return false
        }
        try? await Task.sleep(for: .milliseconds(500))
        return await checkSCKAccess()
    }

    /// Reset TCC entry so the system re-prompts on next request.
    func resetTCCEntry() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.caloura.app"
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
                AppState.shared.statusMessage = "Restart failed: \(description)"
            }
        }
    }

    /// Show a permission guidance alert for a specific diagnosed state.
    func showPermissionAlert(
        for state: PermissionState
    ) {

        let settingsURLString = "x-apple.systempreferences:"
            + "com.apple.preference.security?Privacy_ScreenCapture"
        guard let settingsURL = URL(string: settingsURLString) else {
            return
        }

        switch state {
        case .neverGranted:
            switch permissionDependencies.presentAlert(state) {
            case .openSystemSettings:
                permissionDependencies.openURL(settingsURL)
            case .cancel, .restartApp:
                break
            }
        case .grantedButFailing:
            switch permissionDependencies.presentAlert(state) {
            case .restartApp:
                let bundleURL = Bundle.main.bundleURL
                Task { @MainActor in
                    do {
                        try await permissionDependencies.runRepairTool(
                            URL(filePath: "/usr/bin/open"),
                            ["-n", bundleURL.path]
                        )
                        permissionDependencies.terminateApplication()
                    } catch {
                        let description = error.localizedDescription
                        logger.warning("Restart relaunch failed: \(description, privacy: .public)")
                        AppState.shared.statusMessage = "Restart failed: \(description)"
                    }
                }
            case .openSystemSettings:
                permissionDependencies.openURL(settingsURL)
            case .cancel:
                break
            }
        }
    }
}
