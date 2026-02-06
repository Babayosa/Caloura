import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

extension ScreenCaptureManager {

    // MARK: - Permission

    enum PermissionState {
        case neverGranted
        case grantedButFailing
    }

    /// Quick check using CoreGraphics — no prompt, but may not reflect
    /// SCK status on Sequoia.
    func checkPermission() -> Bool {
        let result = CGPreflightScreenCaptureAccess()
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
        CGRequestScreenCaptureAccess()
    }

    /// Quick single-attempt SCK check for passive status updates
    /// (e.g. app launch). Does not retry or show alerts — just checks
    /// on success. Also sets `sckFailed` so subsequent captures skip
    /// SCK entirely.
    func checkSCKAccess() async -> Bool {
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let displayCount = content.displays.count
            let windowCount = content.windows.count
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

    /// Show a permission guidance alert for a specific diagnosed state.
    func showPermissionAlert(
        for state: PermissionState
    ) {

        let alert = NSAlert()
        alert.alertStyle = .warning
        NSApp.activate()

        let settingsURLString = "x-apple.systempreferences:"
            + "com.apple.preference.security?Privacy_ScreenCapture"

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

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: settingsURLString) {
                    NSWorkspace.shared.open(url)
                }
            }

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
            if response == .alertFirstButtonReturn {
                // Relaunch the app
                let url = Bundle.main.bundleURL
                let task = Process()
                task.executableURL = URL(
                    fileURLWithPath: "/usr/bin/open"
                )
                task.arguments = ["-n", url.path]
                try? task.run()
                NSApp.terminate(nil)
            } else if response == .alertSecondButtonReturn {
                if let url = URL(string: settingsURLString) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
