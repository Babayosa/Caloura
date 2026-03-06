import AppKit
import ImageIO
import os.log

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

extension ScreenCaptureManager {

    // MARK: - screencapture CLI Fallback

    /// Run the macOS `screencapture` CLI tool and load the resulting
    /// image. `screencapture` is a system binary with Apple's own
    /// entitlements, so it can capture all windows even when the
    /// calling app has ad-hoc signing.
    func runScreencapture(args: [String]) async throws -> CGImage {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caloura-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let tempPath = tempURL.path

        // Pre-create the file with restrictive permissions (owner-only
        // read/write) to prevent other users from reading the screenshot
        // during the capture window (TOCTOU mitigation).
        FileManager.default.createFile(
            atPath: tempPath,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )

        let fullArgs = args + ["-x", "-t", "png", tempPath]

        // Run process off main thread to avoid blocking UI
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: "/usr/sbin/screencapture"
            )
            process.arguments = fullArgs
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CaptureError.captureFailed(
                    "screencapture exited with status "
                    + "\(process.terminationStatus)"
                )
            }
        }.value

        // Decode off main thread to avoid UI stalls.
        return try await Task.detached {
            // Load file into memory so we can delete the temp file
            // immediately. CGImageSource with a file URL lazily maps
            // the file — deleting it before pixels are accessed
            // causes EXC_BAD_ACCESS.
            let imageData: Data
            do {
                imageData = try Data(contentsOf: tempURL)
            } catch {
                throw CaptureError.captureFailed(
                    "screencapture output file unreadable: "
                    + "\(error.localizedDescription)"
                )
            }
            guard let source = CGImageSourceCreateWithData(
                imageData as CFData, nil
            ) else {
                throw CaptureError.captureFailed(
                    "Failed to create image source "
                    + "from screencapture output"
                )
            }

            // Force immediate decode so the CGImage is fully in
            // memory and doesn't retain a lazy reference to the
            // source data.
            let decodeOpts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateImageAtIndex(
                source, 0, decodeOpts as CFDictionary
            ) else {
                throw CaptureError.captureFailed(
                    "Failed to decode screencapture output as image"
                )
            }

            return image
        }.value
    }

    func screencaptureFullScreen(
        screen: NSScreen?
    ) async throws -> CGImage {
        let bounds = try fullscreenRectInDisplaySpace(screen: screen)
        return try await runScreencapture(args: [
            "-R\(Int(floor(bounds.origin.x))),"
            + "\(Int(floor(bounds.origin.y))),"
            + "\(Int(bounds.width)),"
            + "\(Int(bounds.height))"
        ])
    }

    func screencaptureArea(
        rect: CGRect,
        screen: NSScreen?
    ) async throws -> CGImage {
        let captureRect = try captureRectInDisplaySpace(
            rect: rect,
            screen: screen
        )

        return try await runScreencapture(args: [
            "-R\(Int(floor(captureRect.origin.x))),"
            + "\(Int(floor(captureRect.origin.y))),"
            + "\(Int(captureRect.width)),"
            + "\(Int(captureRect.height))"
        ])
    }

    func screencaptureAreaInDisplaySpace(
        rect: CGRect
    ) async throws -> CGImage {
        let captureRect = rect.integral
        return try await runScreencapture(args: [
            "-R\(Int(floor(captureRect.origin.x))),"
            + "\(Int(floor(captureRect.origin.y))),"
            + "\(Int(captureRect.width)),"
            + "\(Int(captureRect.height))"
        ])
    }

}
