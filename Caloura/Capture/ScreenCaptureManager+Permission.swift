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
        case signatureMismatch
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

    /// Diagnose the current permission state by combining multiple
    /// signals. CGPreflight is the authoritative OS-level check.
    /// CGWindowList can give false positives on some macOS versions
    /// (returns named windows even when screen recording permission
    /// is denied), so it is only used as a supplementary signal when
    /// CGPreflight confirms permission is granted.
    func diagnosePermissionState() -> PermissionState {
        let cgPreflight = CGPreflightScreenCaptureAccess()

        if cgPreflight {
            // OS confirms permission is granted, but SCK isn't working
            return .grantedButFailing
        }
        return .neverGranted
    }

    /// Show an alert explaining the user needs to grant screen
    /// recording permission. Adapts the message based on whether
    /// permission was never granted or is granted but failing.
    func showPermissionAlert() {
        let state = diagnosePermissionState()
        showPermissionAlert(for: state)
    }

    /// Show a permission guidance alert for a specific diagnosed state.
    func showPermissionAlert( // swiftlint:disable:this function_body_length
        for state: PermissionState
    ) {

        let alert = NSAlert()
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)

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
        case .signatureMismatch:
            alert.messageText = "Permission Granted To Different Build"
            alert.informativeText =
                "Screen Recording appears to be authorized for a "
                + "different Caloura build (for example, App "
                + "Store/Public vs Xcode). Re-grant access for the "
                + "currently running build in System Settings.\n\n"
                + "For stable behavior, run "
                + "/Applications/Caloura.app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: settingsURLString) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
