import Foundation

struct MarkdownExporter {
    // Cached formatter to avoid repeated allocations
    private static let citationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter
    }()
    /// ![Screenshot from AppName](filename.png)
    static func markdownImageTag(for screenshot: ProcessedScreenshot) -> String {
        let altText = escapeMarkdown(altTextFor(screenshot))
        let rawFileName = screenshot.fileName.isEmpty ? "screenshot.png" : screenshot.fileName
        let fileName = percentEncodeFileName(rawFileName)
        return "![\(altText)](\(fileName))"
    }

    /// Markdown image tag with citation line
    /// ![alt](filename)
    /// *Source: Chrome -- CS 101 Lecture (Jan 30, 2026 2:30 PM)*
    static func markdownWithCitation(for screenshot: ProcessedScreenshot) -> String {
        let imageTag = markdownImageTag(for: screenshot)
        let citation = citationLine(for: screenshot)
        return "\(imageTag)\n\(citation)"
    }

    /// <img src="filename.png" alt="Screenshot from AppName" />
    static func htmlImageTag(for screenshot: ProcessedScreenshot) -> String {
        let altText = escapeHTML(altTextFor(screenshot))
        let fileName = escapeHTML(screenshot.fileName.isEmpty ? "screenshot.png" : screenshot.fileName)
        return "<img src=\"\(fileName)\" alt=\"\(altText)\" "
            + "width=\"\(screenshot.width)\" height=\"\(screenshot.height)\" />"
    }

    // MARK: - Helpers

    private static func altTextFor(_ screenshot: ProcessedScreenshot) -> String {
        if let appName = screenshot.context.sourceAppName {
            return "Screenshot from \(appName)"
        }
        return "Screenshot"
    }

    private static func citationLine(for screenshot: ProcessedScreenshot) -> String {
        let dateStr = citationDateFormatter.string(from: screenshot.context.timestamp)

        var parts: [String] = []

        if let appName = screenshot.context.sourceAppName {
            parts.append(escapeMarkdown(appName))
        }
        if let title = screenshot.context.sourceWindowTitle {
            parts.append(escapeMarkdown(title))
        }

        let source = parts.isEmpty ? "Unknown" : parts.joined(separator: " -- ")
        return "*Source: \(source) (\(dateStr))*"
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var result = text
        for char in ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "|", "<", ">", "~"] {
            result = result.replacingOccurrences(of: char, with: "\\\(char)")
        }
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")
        return result
    }

    private static func percentEncodeFileName(_ name: String) -> String {
        // Percent-encode for use inside markdown URL parentheses.
        // Allow common filename characters through; encode the rest.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
