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

    static func openSystemSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}
