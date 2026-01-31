import AppKit
import ScreenCaptureKit

@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    /// Cached result of the last successful SCK authorization check
    private var sckAuthorized: Bool = false

    private init() {}

    // MARK: - Permission

    /// Quick check using CoreGraphics — no prompt, but may not reflect SCK status on Sequoia.
    func checkPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission via CoreGraphics. Only call from explicit user action.
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Verify ScreenCaptureKit authorization by attempting a lightweight query.
    /// Returns true if SCK calls will succeed. Caches the result on success.
    func verifySCKAccess() async -> Bool {
        if sckAuthorized { return true }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            sckAuthorized = true
            return true
        } catch {
            sckAuthorized = false
            return false
        }
    }

    /// Show an alert explaining the user needs to grant screen recording permission.
    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "SnapNote needs screen recording access to capture screenshots.\n\n1. Click \"Open System Settings\" below\n2. Find SnapNote in the list and toggle it ON\n3. You may need to quit and reopen SnapNote after granting access"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Full Screen Capture

    func captureFullScreen(screen: NSScreen? = nil) async throws -> CGImage {
        let content = try await SCShareableContent.current
        let targetScreen = screen ?? NSScreen.main!

        guard let scDisplay = content.displays.first(where: { display in
            display.displayID == targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = scDisplay.width * 2  // Retina
        config.height = scDisplay.height * 2
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    // MARK: - Window Capture

    func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    // MARK: - Area Capture

    func captureArea(rect: CGRect, screen: NSScreen? = nil) async throws -> CGImage {
        let content = try await SCShareableContent.current
        let targetScreen = screen ?? NSScreen.main!

        guard let scDisplay = content.displays.first(where: { display in
            display.displayID == targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()

        // Convert from AppKit coordinates (bottom-left) to ScreenCaptureKit (top-left)
        let screenFrame = targetScreen.frame
        let flippedY = screenFrame.height - rect.origin.y - rect.height

        let scale = targetScreen.backingScaleFactor
        config.sourceRect = CGRect(
            x: rect.origin.x,
            y: flippedY,
            width: rect.width,
            height: rect.height
        )
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    // MARK: - Window Enumeration

    func getWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return content.windows.filter { window in
            guard let title = window.title, !title.isEmpty else { return false }
            guard window.isOnScreen else { return false }
            // Exclude our own app
            return window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
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
            return "Screen recording permission is required. Please enable it in System Settings > Privacy & Security > Screen Recording."
        case .captureFailed(let reason):
            return "Capture failed: \(reason)"
        case .cancelled:
            return "Capture was cancelled."
        }
    }
}
