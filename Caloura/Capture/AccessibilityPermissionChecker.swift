import AppKit

enum AccessibilityPermissionChecker {
    static func isGranted() -> Bool { AXIsProcessTrusted() }

    static func openSystemSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}
