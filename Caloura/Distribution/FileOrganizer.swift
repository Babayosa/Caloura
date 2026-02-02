import Foundation

struct FileOrganizer {
    /// Save screenshot to disk with organized folder structure
    /// ~/Pictures/Caloura/YYYY-MM-DD/Caloura_HH-mm-ss_AppName.{png,jpeg,tiff}
    @discardableResult
    static func save(
        _ screenshot: ProcessedScreenshot,
        baseDirectory: String,
        subfolder: String? = nil,
        imageFormat: String = "png"
    ) throws -> URL {
        let baseURL = URL(fileURLWithPath: baseDirectory)

        // Date-based subfolder
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolder = dateFormatter.string(from: screenshot.context.timestamp)

        var directoryURL = baseURL.appendingPathComponent(dateFolder)

        // Optional context subfolder (e.g., "Lectures", "Code")
        if let subfolder = subfolder, !subfolder.isEmpty {
            directoryURL = baseURL.appendingPathComponent(subfolder).appendingPathComponent(dateFolder)
        }

        // Create directory if needed
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Generate filename
        let fileName = generateFileName(for: screenshot, imageFormat: imageFormat)
        let fileURL = directoryURL.appendingPathComponent(fileName)

        // Encode image in the requested format
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
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH-mm-ss"
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
