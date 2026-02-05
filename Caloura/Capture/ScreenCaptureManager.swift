import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "ScreenCapture")

@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    /// Once SCK fails (e.g. debug build), skip it on subsequent captures
    /// to avoid repeated system prompts and latency.
    var sckFailed: Bool = false

    /// Cache app icons by bundle ID to avoid repeated lookups
    private var iconCache = NSCache<NSString, NSImage>()

    init() {
        iconCache.countLimit = 50 // Limit cache size
    }

    /// Get app icon, using cache to avoid repeated lookups
    func cachedIcon(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        if let icon = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?.icon {
            iconCache.setObject(icon, forKey: key)
            return icon
        }
        return nil
    }

    // MARK: - Full Screen Capture

    /// Capture the full screen, falling back through SCK, CLI, and CG backends.
    func captureFullScreen(screen: NSScreen? = nil) async throws -> CGImage {
        if !sckFailed {
            do {
                return try await sckCaptureFullScreen(screen: screen)
            } catch {
                logger.warning(
                    "SCK captureFullScreen failed: \(error.localizedDescription)"
                )
                sckFailed = true
            }
        }
        // Try screencapture CLI (has its own entitlements, no permission gate needed)
        do {
            logger.info("Trying screencapture CLI for fullscreen")
            return try await screencaptureFullScreen(screen: screen)
        } catch {
            logger.warning(
                "screencapture CLI failed: \(error.localizedDescription), falling back to CG"
            )
        }
        // CG fallback requires confirmed permission — CGPreflight is authoritative
        guard checkPermission() else { throw CaptureError.noPermission }
        return try cgCaptureFullScreen(screen: screen)
    }

    // MARK: - Area Capture

    /// Capture a rectangular region of the screen, falling back through SCK, CLI, and CG backends.
    func captureArea(
        rect: CGRect,
        screen: NSScreen? = nil
    ) async throws -> CGImage {
        if !sckFailed {
            do {
                return try await sckCaptureArea(rect: rect, screen: screen)
            } catch {
                logger.warning(
                    "SCK captureArea failed: \(error.localizedDescription)"
                )
                sckFailed = true
            }
        }

        do {
            logger.info("Trying screencapture CLI for area")
            return try await screencaptureArea(rect: rect, screen: screen)
        } catch {
            logger.warning(
                "screencapture CLI failed: \(error.localizedDescription), falling back to CG"
            )
        }
        guard checkPermission() else { throw CaptureError.noPermission }
        return try cgCaptureArea(rect: rect, screen: screen)
    }

    // MARK: - Window Capture

    /// Capture directly from an SCContentFilter (used by WindowPickerManager).
    /// This is the fastest path — no window lookup needed.
    func captureWindow(filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = Int(
            filter.contentRect.width * CGFloat(filter.pointPixelScale)
        )
        config.height = Int(
            filter.contentRect.height * CGFloat(filter.pointPixelScale)
        )
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

    /// Capture a window by its CaptureWindow descriptor,
    /// falling back through SCK, CLI, and CG backends.
    func captureWindow(_ window: CaptureWindow) async throws -> CGImage {
        if let scWindow = window.scWindow, !sckFailed {
            do {
                return try await sckCaptureWindow(scWindow)
            } catch {
                logger.warning(
                    "SCK captureWindow failed: \(error.localizedDescription)"
                )
                sckFailed = true
            }
        }

        do {
            logger.info("Trying screencapture CLI for window \(window.id)")
            return try await screencaptureWindow(windowID: window.id)
        } catch {
            logger.warning(
                "screencapture CLI failed: \(error.localizedDescription), falling back to CG"
            )
        }
        guard checkPermission() else { throw CaptureError.noPermission }
        return try cgCaptureWindow(windowID: window.id)
    }

    // MARK: - Window Enumeration

    /// Return all on-screen windows (excluding this app), sorted in front-to-back z-order.
    func getWindows() async throws -> [CaptureWindow] {
        if !sckFailed {
            do {
                let scWindows = try await sckGetWindows()
                var captureWindows = scWindows.compactMap { window -> CaptureWindow? in
                    let frame = window.frame
                    // Skip tiny utility windows and status items
                    guard frame.width >= 50, frame.height >= 50 else {
                        return nil
                    }
                    // Use cached icon lookup
                    let icon: NSImage? = {
                        guard let bid = window.owningApplication?.bundleIdentifier
                        else { return nil }
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
                        uniqueKeysWithValues: zOrderIDs.enumerated()
                            .map { ($1, $0) }
                    )
                    captureWindows.sort { lhs, rhs in
                        (orderIndex[lhs.id] ?? Int.max)
                            < (orderIndex[rhs.id] ?? Int.max)
                    }
                }

                return captureWindows
            } catch {
                logger.warning(
                    "SCK getWindows failed: \(error.localizedDescription)"
                )
                sckFailed = true
            }
        }
        if checkPermission() {
            return getWindowsCG()
        }
        throw CaptureError.noPermission
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
            return "Screen recording permission is required. "
                + "Please enable it in System Settings "
                + "> Privacy & Security > Screen Recording."
        case .captureFailed(let reason):
            return "Capture failed: \(reason)"
        case .cancelled:
            return "Capture was cancelled."
        }
    }
}
