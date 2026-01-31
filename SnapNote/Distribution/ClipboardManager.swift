import AppKit
import Foundation

struct ClipboardManager {
    private static let pasteboard = NSPasteboard.general

    /// Copy image to clipboard as TIFF + PNG
    static func copyImage(_ screenshot: ProcessedScreenshot) {
        pasteboard.clearContents()
        pasteboard.setData(
            ImageProcessor.tiffRepresentation(of: screenshot.cgImage),
            forType: .tiff
        )
        pasteboard.setData(
            screenshot.pngData,
            forType: .png
        )
    }

    /// Copy as Markdown text: ![alt](filename)
    static func copyAsMarkdown(_ screenshot: ProcessedScreenshot) {
        let markdown = MarkdownExporter.markdownImageTag(for: screenshot)
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    /// Copy as Markdown with citation
    static func copyWithCitation(_ screenshot: ProcessedScreenshot) {
        let citation = MarkdownExporter.markdownWithCitation(for: screenshot)
        pasteboard.clearContents()
        pasteboard.setString(citation, forType: .string)
    }

    /// Copy OCR text
    static func copyOCRText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copy multi-format: image + Markdown + HTML simultaneously
    /// Rich text editors get the image, plain text editors get markdown
    static func copyMultiFormat(_ screenshot: ProcessedScreenshot) {
        pasteboard.clearContents()

        // Image formats
        pasteboard.setData(
            ImageProcessor.tiffRepresentation(of: screenshot.cgImage),
            forType: .tiff
        )
        pasteboard.setData(
            screenshot.pngData,
            forType: .png
        )

        // Plain text (Markdown)
        let markdown = MarkdownExporter.markdownImageTag(for: screenshot)
        pasteboard.setString(markdown, forType: .string)

        // HTML
        let html = MarkdownExporter.htmlImageTag(for: screenshot)
        pasteboard.setData(
            html.data(using: .utf8) ?? Data(),
            forType: .html
        )
    }
}
