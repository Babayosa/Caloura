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

        // Move encoding + file I/O to background thread
        let (savedURL, cachedPNGData) = try await Task.detached(priority: .userInitiated) {
            let imageData: Data
            var pngCache: Data?

            switch format {
            case "jpeg":
                imageData = ImageProcessor.jpegRepresentation(of: cgImage)
            case "tiff":
                imageData = ImageProcessor.tiffRepresentation(of: cgImage)
            default:
                let data = ImageProcessor.pngRepresentation(of: cgImage)
                imageData = data
                pngCache = data
            }

            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try imageData.write(to: fileURL)
            return (fileURL, pngCache)
        }.value

        if let cachedPNGData {
            screenshot.cachePNGData(cachedPNGData)
        }

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
            attributes: nil
        )

        let fileName = generateFileName(for: screenshot, imageFormat: imageFormat)
        let fileURL = directoryURL.appendingPathComponent(fileName)

        let imageData: Data
        switch imageFormat {
        case "jpeg":
            imageData = ImageProcessor.jpegRepresentation(of: screenshot.cgImage)
        case "tiff":
            imageData = ImageProcessor.tiffRepresentation(of: screenshot.cgImage)
        default:
            imageData = screenshot.pngData
        }
        try imageData.write(to: fileURL)

        return fileURL
    }

    /// Generate filename: Caloura_HH-mm-ss_AppName.{ext}
    static func generateFileName(for screenshot: ProcessedScreenshot, imageFormat: String = "png") -> String {
        let timeStr = timeFormatter.string(from: screenshot.context.timestamp)

        let appName = screenshot.context.sourceAppName?
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "-")
            ?? "Unknown"

        let ext: String
        switch imageFormat {
        case "jpeg": ext = "jpeg"
        case "tiff": ext = "tiff"
        default: ext = "png"
        }

        return "Caloura_\(timeStr)_\(appName).\(ext)"
    }

    /// Ensure the base save directory exists
    static func ensureBaseDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
