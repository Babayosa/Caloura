import AppKit
import ImageIO
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "ScreenCapture")

@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    /// Once SCK fails (e.g. debug build), skip it on subsequent captures
    /// to avoid repeated system prompts and latency.
    private var sckFailed: Bool = false

    /// Cache app icons by bundle ID to avoid repeated lookups
    private var iconCache = NSCache<NSString, NSImage>()

    private init() {
        iconCache.countLimit = 50 // Limit cache size
    }

    /// Get app icon, using cache to avoid repeated lookups
    private func cachedIcon(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon {
            iconCache.setObject(icon, forKey: key)
            return icon
        }
        return nil
    }

    // MARK: - Permission

    enum PermissionState {
        case neverGranted
        case grantedButFailing
    }

    /// Quick check using CoreGraphics — no prompt, but may not reflect SCK status on Sequoia.
    func checkPermission() -> Bool {
        let result = CGPreflightScreenCaptureAccess()
        logger.info("CGPreflightScreenCaptureAccess: \(result)")
        return result
    }

    /// Request screen recording permission via CoreGraphics. Only call from explicit user action.
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Quick single-attempt SCK check for passive status updates (e.g. app launch).
    /// Does not retry or show alerts — just checks on success.
    /// Also sets `sckFailed` so subsequent captures skip SCK entirely.
    func checkSCKAccess() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            logger.info("SCK check: authorized (\(content.displays.count) displays, \(content.windows.count) windows)")
            sckFailed = false
            return true
        } catch {
            logger.info("SCK check: not authorized (\(error.localizedDescription))")
            sckFailed = true
            return false
        }
    }

    /// Diagnose the current permission state by combining multiple signals.
    /// CGPreflight is the authoritative OS-level check. CGWindowList can give
    /// false positives on some macOS versions (returns named windows even when
    /// screen recording permission is denied), so it is only used as a
    /// supplementary signal when CGPreflight confirms permission is granted.
    func diagnosePermissionState() -> PermissionState {
        let cgPreflight = CGPreflightScreenCaptureAccess()

        if cgPreflight {
            // OS confirms permission is granted, but SCK isn't working
            return .grantedButFailing
        }
        return .neverGranted
    }

    /// Show an alert explaining the user needs to grant screen recording permission.
    /// Adapts the message based on whether permission was never granted or is granted but failing.
    func showPermissionAlert() {
        let state = diagnosePermissionState()

        let alert = NSAlert()
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)

        switch state {
        case .neverGranted:
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Caloura needs screen recording access to capture screenshots.\n\n1. Click \"Open System Settings\" below\n2. Find Caloura in the list and toggle it ON\n3. You may need to quit and reopen Caloura after granting access"
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }

        case .grantedButFailing:
            alert.messageText = "Screen Recording Permission Issue"
            alert.informativeText = "Caloura has screen recording permission, but macOS is not allowing captures. This can happen after an app update or system change.\n\nRestarting Caloura usually fixes this. If not, try toggling the permission off and on in System Settings."
            alert.addButton(withTitle: "Restart Caloura")
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Relaunch the app
                let url = Bundle.main.bundleURL
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-n", url.path]
                try? task.run()
                NSApp.terminate(nil)
            } else if response == .alertSecondButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - Full Screen Capture

    func captureFullScreen(screen: NSScreen? = nil) async throws -> CGImage {
        if !sckFailed {
            do {
                return try await sckCaptureFullScreen(screen: screen)
            } catch {
                logger.warning("SCK captureFullScreen failed: \(error.localizedDescription)")
                sckFailed = true
            }
        }
        // Try screencapture CLI (has its own entitlements, no permission gate needed)
        do {
            logger.info("Trying screencapture CLI for fullscreen")
            return try await screencaptureFullScreen(screen: screen)
        } catch {
            logger.warning("screencapture CLI failed: \(error.localizedDescription), falling back to CG")
        }
        // CG fallback requires confirmed permission — CGPreflight is authoritative
        guard checkPermission() else { throw CaptureError.noPermission }
        return try cgCaptureFullScreen(screen: screen)
    }

    // MARK: - Area Capture

    func captureArea(rect: CGRect, screen: NSScreen? = nil) async throws -> CGImage {
        if !sckFailed {
            do {
                return try await sckCaptureArea(rect: rect, screen: screen)
            } catch {
                logger.warning("SCK captureArea failed: \(error.localizedDescription)")
                sckFailed = true
            }
        }

        do {
            logger.info("Trying screencapture CLI for area")
            return try await screencaptureArea(rect: rect, screen: screen)
        } catch {
            logger.warning("screencapture CLI failed: \(error.localizedDescription), falling back to CG")
        }
        guard checkPermission() else { throw CaptureError.noPermission }
        return try cgCaptureArea(rect: rect, screen: screen)
    }

    // MARK: - Window Capture

    /// Capture directly from an SCContentFilter (used by WindowPickerManager).
    /// This is the fastest path — no window lookup needed.
    func captureWindow(filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = true

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// Capture a window directly from an SCWindow reference.
    func captureWindow(scWindow: SCWindow) async throws -> CGImage {
        return try await sckCaptureWindow(scWindow)
    }

    func captureWindow(_ window: CaptureWindow) async throws -> CGImage {
        if let scWindow = window.scWindow, !sckFailed {
            do {
                return try await sckCaptureWindow(scWindow)
            } catch {
                logger.warning("SCK captureWindow failed: \(error.localizedDescription)")
                sckFailed = true
            }
        }

        do {
            logger.info("Trying screencapture CLI for window \(window.id)")
            return try await screencaptureWindow(windowID: window.id)
        } catch {
            logger.warning("screencapture CLI failed: \(error.localizedDescription), falling back to CG")
        }
        guard checkPermission() else { throw CaptureError.noPermission }
        return try cgCaptureWindow(windowID: window.id)
    }

    // MARK: - Window Enumeration

    func getWindows() async throws -> [CaptureWindow] {
        if !sckFailed {
            do {
                let scWindows = try await sckGetWindows()
                var captureWindows = scWindows.compactMap { window -> CaptureWindow? in
                    let frame = window.frame
                    // Skip tiny utility windows and status items
                    guard frame.width >= 50, frame.height >= 50 else { return nil }
                    // Use cached icon lookup
                    let icon: NSImage? = {
                        guard let bid = window.owningApplication?.bundleIdentifier else { return nil }
                        return cachedIcon(for: bid)
                    }()
                    return CaptureWindow(
                        id: window.windowID,
                        title: window.title ?? "Untitled",
                        appName: window.owningApplication?.applicationName ?? "",
                        frame: frame,
                        scWindow: window,
                        appIcon: icon
                    )
                }

                // SCK does not guarantee z-order — sort by CG front-to-back order
                let zOrderIDs = zOrderedWindowIDs()
                if !zOrderIDs.isEmpty {
                    let orderIndex = Dictionary(
                        uniqueKeysWithValues: zOrderIDs.enumerated().map { ($1, $0) }
                    )
                    captureWindows.sort { a, b in
                        (orderIndex[a.id] ?? Int.max) < (orderIndex[b.id] ?? Int.max)
                    }
                }

                return captureWindows
            } catch {
                logger.warning("SCK getWindows failed: \(error.localizedDescription)")
                sckFailed = true
            }
        }
        if checkPermission() {
            return getWindowsCG()
        }
        throw CaptureError.noPermission
    }

    // MARK: - SCK Capture (Private)

    private func sckCaptureFullScreen(screen: NSScreen?) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }

        guard let scDisplay = content.displays.first(where: { display in
            display.displayID == targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = Int(targetScreen.backingScaleFactor)
        config.width = scDisplay.width * scale
        config.height = scDisplay.height * scale
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    private func sckCaptureArea(rect: CGRect, screen: NSScreen?) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }

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

    private func sckCaptureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    private func sckGetWindows() async throws -> [SCWindow] {
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

    // MARK: - screencapture CLI Fallback (Private)

    /// Run the macOS `screencapture` CLI tool and load the resulting image.
    /// `screencapture` is a system binary with Apple's own entitlements, so it can
    /// capture all windows even when the calling app has ad-hoc signing.
    private func runScreencapture(args: [String]) async throws -> CGImage {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-\(UUID().uuidString).png")
        let tempPath = tempURL.path
        let fullArgs = args + ["-x", "-t", "png", tempPath]

        // Run process off main thread to avoid blocking UI
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = fullArgs
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CaptureError.captureFailed(
                    "screencapture exited with status \(process.terminationStatus)"
                )
            }
        }.value

        // Decode off main thread to avoid UI stalls.
        return try await Task.detached {
            // Load file into memory so we can delete the temp file immediately.
            // CGImageSource with a file URL lazily maps the file — deleting it
            // before pixels are accessed causes EXC_BAD_ACCESS.
            let imageData: Data
            do {
                imageData = try Data(contentsOf: tempURL)
            } catch {
                throw CaptureError.captureFailed("screencapture output file unreadable: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: tempURL)

            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                throw CaptureError.captureFailed("Failed to create image source from screencapture output")
            }

            // Force immediate decode so the CGImage is fully in memory
            // and doesn't retain a lazy reference to the source data.
            let decodeOpts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOpts as CFDictionary) else {
                throw CaptureError.captureFailed("Failed to decode screencapture output as image")
            }

            return image
        }.value
    }

    private func screencaptureFullScreen(screen: NSScreen?) async throws -> CGImage {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        guard let displayID = targetScreen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else {
            throw CaptureError.noDisplay
        }
        let bounds = CGDisplayBounds(displayID)
        return try await runScreencapture(args: [
            "-R\(Int(bounds.origin.x)),\(Int(bounds.origin.y)),\(Int(bounds.width)),\(Int(bounds.height))"
        ])
    }

    private func screencaptureArea(rect: CGRect, screen: NSScreen?) async throws -> CGImage {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        guard let displayID = targetScreen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else {
            throw CaptureError.noDisplay
        }
        let screenFrame = targetScreen.frame
        let displayBounds = CGDisplayBounds(displayID)

        // Convert AppKit local coords (bottom-left origin) to global CG coords (top-left origin)
        let localCGY = screenFrame.height - rect.origin.y - rect.height
        let globalX = displayBounds.origin.x + rect.origin.x
        let globalY = displayBounds.origin.y + localCGY

        return try await runScreencapture(args: [
            "-R\(Int(globalX)),\(Int(globalY)),\(Int(rect.width)),\(Int(rect.height))"
        ])
    }

    private func screencaptureWindow(windowID: CGWindowID) async throws -> CGImage {
        return try await runScreencapture(args: ["-o", "-l\(windowID)"])
    }

    // MARK: - CoreGraphics Fallback Capture (Private)
    // Note: In debug builds with ad-hoc signing, CG capture may only include
    // the desktop and Caloura's own windows. Other apps' windows require
    // effective screen recording permission tied to a stable code signature.
    //
    // DEPRECATED: CGWindowListCreateImage is deprecated in macOS 15 (Sequoia).
    // These CG fallback methods are retained for graceful degradation on macOS 14
    // but should be removed when the deployment target moves to 15.0+.
    // Prefer ScreenCaptureKit (SCK) for all capture operations.

    private func cgCaptureFullScreen(screen: NSScreen?) throws -> CGImage {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        guard let displayID = targetScreen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else {
            throw CaptureError.noDisplay
        }
        let displayBounds = CGDisplayBounds(displayID)
        guard let image = CGWindowListCreateImage(
            displayBounds, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
        ) else {
            throw CaptureError.captureFailed("CGWindowListCreateImage returned nil for display")
        }
        return image
    }

    private func cgCaptureArea(rect: CGRect, screen: NSScreen?) throws -> CGImage {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.noDisplay
        }
        let screenFrame = targetScreen.frame
        // Convert AppKit coords (bottom-left) to CG coords (top-left)
        let cgRect = CGRect(
            x: rect.origin.x,
            y: screenFrame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        guard let image = CGWindowListCreateImage(
            cgRect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
        ) else {
            throw CaptureError.captureFailed("CGWindowListCreateImage returned nil")
        }
        return image
    }

    private func cgCaptureWindow(windowID: CGWindowID) throws -> CGImage {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            throw CaptureError.captureFailed("CGWindowListCreateImage returned nil for window \(windowID)")
        }
        return image
    }

    // MARK: - CoreGraphics Window Enumeration
    // DEPRECATED: CGWindowListCopyWindowInfo is deprecated in macOS 15.
    // Remove when deployment target moves to 15.0+.

    /// Returns layer-0 (normal) window IDs in front-to-back z-order using CG metadata.
    /// No screen recording permission needed for metadata on Sequoia.
    private func zOrderedWindowIDs() -> [CGWindowID] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return []
        }
        return windowList.compactMap { info in
            guard let layer = info[kCGWindowLayer] as? Int, layer == 0 else { return nil }
            return info[kCGWindowNumber] as? CGWindowID
        }
    }

    private func getWindowsCG() -> [CaptureWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return []
        }

        let bundleID = Bundle.main.bundleIdentifier
        var results: [CaptureWindow] = []

        for info in windowList {
            guard let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let ownerName = info[kCGWindowOwnerName] as? String,
                  let layer = info[kCGWindowLayer] as? Int,
                  layer == 0  // Normal window layer
            else { continue }

            // Skip our own app
            if let ownerPID = info[kCGWindowOwnerPID] as? pid_t {
                if let runningApp = NSRunningApplication(processIdentifier: ownerPID),
                   runningApp.bundleIdentifier == bundleID {
                    continue
                }
            }

            let title = info[kCGWindowName] as? String ?? ""
            guard !title.isEmpty else { continue }

            // Extract window bounds
            guard let boundsDict = info[kCGWindowBounds] as? NSDictionary as CFDictionary?,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            // Skip tiny utility windows and status items
            guard frame.width >= 50, frame.height >= 50 else { continue }

            let icon: NSImage? = (info[kCGWindowOwnerPID] as? pid_t).flatMap {
                NSRunningApplication(processIdentifier: $0)?.icon
            }

            results.append(CaptureWindow(
                id: windowID,
                title: title,
                appName: ownerName,
                frame: frame,
                scWindow: nil,
                appIcon: icon
            ))
        }

        return results
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
