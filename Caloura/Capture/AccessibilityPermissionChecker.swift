import AppKit

enum AccessibilityState: Equatable {
    case notRequested
    case denied
    case working
}

enum AccessibilityPermissionChecker {
    static func currentState() -> AccessibilityState {
        AXIsProcessTrusted() ? .working : .denied
    }

    static func isGranted() -> Bool {
        currentState() == .working
    }

    /// Prompt the system accessibility dialog if not yet trusted.
    /// Returns `true` if the process is already trusted.
    static func requestAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        )
    }
}
