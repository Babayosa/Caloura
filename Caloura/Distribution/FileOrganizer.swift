import Foundation

struct FileOrganizer {
    // MARK: - Cached Formatters (avoid recreating on every save)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH-mm-ss"
        return formatter
    }()

    /// Save screenshot to disk with organized folder structure.
    /// Runs file I/O on a background thread to avoid blocking the main thread.
    @discardableResult
    static func save(
        _ screenshot: ProcessedScreenshot,
        baseDirectory: String,
        subfolder: String? = nil,
        imageFormat: String = "png"
    ) async throws -> URL {
        // Prepare all data on current thread (fast)
        let baseURL = URL(fileURLWithPath: baseDirectory)
        let dateFolder = dateFormatter.string(from: screenshot.context.timestamp)

        var directoryURL = baseURL.appendingPathComponent(dateFolder)
        if let subfolder = subfolder, !subfolder.isEmpty {
            directoryURL = baseURL.appendingPathComponent(subfolder).appendingPathComponent(dateFolder)
        }

        let fileName = generateFileName(for: screenshot, imageFormat: imageFormat)
        let fileURL = directoryURL.appendingPathComponent(fileName)

        let cgImage = screenshot.cgImage
        let format = imageFormat

        try validatePathSafety(url: fileURL, baseDirectory: baseDirectory)

        // Move encoding + file I/O to background thread
        let savedURL = try await Task.detached(priority: .userInitiated) {
            let imageData: Data

            switch format {
            case "jpeg":
                imageData = try ImageProcessor.jpegRepresentation(of: cgImage)
            case "tiff":
                imageData = screenshot.tiffData
            default:
                imageData = screenshot.pngData
            }

            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try imageData.write(to: fileURL)
            return fileURL
        }.value

        return savedURL
    }

    /// Synchronous save for cases where async isn't available.
    /// Prefer the async version when possible.
    @discardableResult
    static func saveSync(
        _ screenshot: ProcessedScreenshot,
        baseDirectory: String,
        subfolder: String? = nil,
        imageFormat: String = "png"
    ) throws -> URL {
        let baseURL = URL(fileURLWithPath: baseDirectory)
        let dateFolder = dateFormatter.string(from: screenshot.context.timestamp)

        var directoryURL = baseURL.appendingPathComponent(dateFolder)
        if let subfolder = subfolder, !subfolder.isEmpty {
            directoryURL = baseURL.appendingPathComponent(subfolder).appendingPathComponent(dateFolder)
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fileName = generateFileName(for: screenshot, imageFormat: imageFormat)
        let fileURL = directoryURL.appendingPathComponent(fileName)

        let imageData: Data
        switch imageFormat {
        case "jpeg":
            imageData = try ImageProcessor.jpegRepresentation(of: screenshot.cgImage)
        case "tiff":
            imageData = screenshot.tiffData
        default:
            imageData = screenshot.pngData
        }
        try validatePathSafety(url: fileURL, baseDirectory: baseDirectory)
        try imageData.write(to: fileURL)

        return fileURL
    }

    /// Generate filename: Caloura_HH-mm-ss_AppName.{ext}
    static func generateFileName(for screenshot: ProcessedScreenshot, imageFormat: String = "png") -> String {
        let timeStr = timeFormatter.string(from: screenshot.context.timestamp)
        let appName = sanitizeFileName(screenshot.context.sourceAppName ?? "Unknown")

        let ext: String
        switch imageFormat {
        case "jpeg": ext = "jpeg"
        case "tiff": ext = "tiff"
        default: ext = "png"
        }

        return "Caloura_\(timeStr)_\(appName).\(ext)"
    }

    /// Sanitize a string for safe use in filenames.
    /// Allows alphanumeric characters and hyphens only, truncated to 50 chars.
    static func sanitizeFileName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
        let result = String(String.UnicodeScalarView(cleaned))
        if result.isEmpty { return "Unknown" }
        return String(result.prefix(50))
    }

    /// Ensure the base save directory exists
    static func ensureBaseDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Path Safety

    enum FileOrganizerError: LocalizedError {
        case pathTraversal

        var errorDescription: String? {
            switch self {
            case .pathTraversal:
                return "Save path resolved outside the base directory"
            }
        }
    }

    /// Verify that a resolved path stays within the expected base directory.
    private static func validatePathSafety(url: URL, baseDirectory: String) throws {
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedBase = URL(fileURLWithPath: baseDirectory)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(resolvedBase + "/") || resolvedPath == resolvedBase else {
            throw FileOrganizerError.pathTraversal
        }
    }
}
