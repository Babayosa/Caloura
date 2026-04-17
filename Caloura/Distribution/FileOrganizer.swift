import CoreGraphics
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
        formatter.dateFormat = "HH-mm-ss-SSS"
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
        try await save(
            cgImage: screenshot.cgImage,
            context: screenshot.context,
            baseDirectory: baseDirectory,
            subfolder: subfolder,
            imageFormat: imageFormat,
            smartFileName: screenshot.fileName.isEmpty ? nil : screenshot.fileName.deletingPathExtension
        )
    }

    @discardableResult
    static func save(
        cgImage: CGImage,
        context: CaptureContext,
        baseDirectory: String,
        subfolder: String? = nil,
        imageFormat: String = "png",
        smartFileName: String? = nil
    ) async throws -> URL {
        // Prepare all data on current thread (fast)
        let baseURL = URL(fileURLWithPath: baseDirectory)
        let dateFolder = dateFormatter.string(from: context.timestamp)

        var directoryURL = baseURL.appendingPathComponent(dateFolder)
        if let subfolder = subfolder, !subfolder.isEmpty {
            directoryURL = baseURL.appendingPathComponent(subfolder).appendingPathComponent(dateFolder)
        }

        let fileName = generateFileName(
            for: context,
            imageFormat: imageFormat,
            smartFileName: smartFileName
        )
        let fileURL = directoryURL.appendingPathComponent(fileName)

        try validatePathSafety(url: fileURL, baseDirectory: baseDirectory)

        // Move encoding + file I/O to background thread
        let savedURL = try await Task.detached(priority: .userInitiated) {
            let imageData = try encodedData(for: cgImage, imageFormat: imageFormat)
            try prepareDirectory(at: directoryURL)
            let uniqueFileURL = uniqueFileURL(
                in: directoryURL,
                preferredName: fileName
            )
            try writeImageData(imageData, to: uniqueFileURL)
            return uniqueFileURL
        }.value

        return savedURL
    }

    /// Generate filename: uses smartFileName if available, otherwise Caloura_HH-mm-ss_AppName.{ext}
    static func generateFileName(
        for context: CaptureContext,
        imageFormat: String = "png",
        smartFileName: String? = nil
    ) -> String {
        let ext: String
        switch imageFormat {
        case "jpeg": ext = "jpeg"
        case "tiff": ext = "tiff"
        case "heic": ext = "heic"
        default: ext = "png"
        }

        if let smart = smartFileName {
            let sanitized = sanitizeFileName(smart)
            if sanitized != "Unknown" {
                return "\(sanitized).\(ext)"
            }
        }

        let timeStr = timeFormatter.string(from: context.timestamp)
        let appName = sanitizeFileName(context.sourceAppName ?? "Unknown")
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

    enum FileOrganizerError: LocalizedError, Equatable {
        case pathTraversal
        case unsupportedImageFormat(String)

        var errorDescription: String? {
            switch self {
            case .pathTraversal:
                return "Save path resolved outside the base directory"
            case .unsupportedImageFormat(let format):
                return "Unsupported image format: \(format)"
            }
        }
    }

    static func overwrite(
        cgImage: CGImage,
        at url: URL,
        imageFormat: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let imageData = try encodedData(for: cgImage, imageFormat: imageFormat)
            try writeImageData(imageData, to: url)
        }.value
    }

    static func imageFormat(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "jpeg"
        case "tif", "tiff":
            return "tiff"
        case "heic", "heif":
            return "heic"
        default:
            return "png"
        }
    }

    /// Verify that a resolved path stays within the expected base directory.
    /// Checks both the standardized full path (catches `..` traversal) and
    /// the deepest existing ancestor with symlinks resolved (catches symlink
    /// escapes even when child directories haven't been created yet).
    private static func validatePathSafety(url: URL, baseDirectory: String) throws {
        let resolvedBase = URL(fileURLWithPath: baseDirectory)
            .resolvingSymlinksInPath().standardizedFileURL.path

        // Check 1: standardized full path catches `..` traversal
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(resolvedBase + "/") || resolvedPath == resolvedBase else {
            throw FileOrganizerError.pathTraversal
        }

        // Check 2: walk up to deepest existing ancestor, resolve symlinks there.
        // resolvingSymlinksInPath can't follow symlinks in non-existent paths,
        // so we find the first existing parent and verify it's within base
        // (or is itself an ancestor of the base, which is safe).
        var ancestor = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        let resolvedAncestor = ancestor.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let ancestorInBase = resolvedAncestor.hasPrefix(resolvedBase + "/")
            || resolvedAncestor == resolvedBase
        let ancestorIsParentOfBase = resolvedAncestor == "/"
            || (resolvedBase + "/").hasPrefix(resolvedAncestor + "/")
        guard ancestorInBase || ancestorIsParentOfBase else {
            throw FileOrganizerError.pathTraversal
        }
    }

    private static func prepareDirectory(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func uniqueFileURL(in directoryURL: URL, preferredName: String) -> URL {
        let preferredURL = directoryURL.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let extensionName = preferredURL.pathExtension
        let baseName = preferredURL.deletingPathExtension().lastPathComponent

        for suffix in 2...10_000 {
            let candidateName = "\(baseName)-\(suffix).\(extensionName)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return directoryURL.appendingPathComponent(
            "\(baseName)-\(UUID().uuidString.prefix(8)).\(extensionName)"
        )
    }

    private static func writeImageData(_ imageData: Data, to fileURL: URL) throws {
        try imageData.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func encodedData(
        for cgImage: CGImage,
        imageFormat: String
    ) throws -> Data {
        switch imageFormat {
        case "jpeg":
            return try ImageProcessor.jpegRepresentation(of: cgImage)
        case "tiff":
            return try ImageProcessor.tiffRepresentation(of: cgImage)
        case "heic":
            return try ImageProcessor.heicRepresentation(of: cgImage)
        case "png":
            return try ImageProcessor.pngRepresentation(of: cgImage)
        default:
            throw FileOrganizerError.unsupportedImageFormat(imageFormat)
        }
    }
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}
