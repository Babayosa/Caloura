import AppKit
import Foundation

struct ClipboardManager {
    private static let pasteboard = NSPasteboard.general

    /// Copy image to clipboard as TIFF + PNG
    static func copyImage(_ screenshot: ProcessedScreenshot) async {
        let imageData = await imageData(for: screenshot)
        await MainActor.run {
            pasteboard.clearContents()
            pasteboard.setData(imageData.tiff, forType: .tiff)
            pasteboard.setData(imageData.png, forType: .png)
        }
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
    static func copyMultiFormat(_ screenshot: ProcessedScreenshot) async {
        let imageData = await imageData(for: screenshot)
        let markdown = MarkdownExporter.markdownImageTag(for: screenshot)
        let html = MarkdownExporter.htmlImageTag(for: screenshot)
        await MainActor.run {
            pasteboard.clearContents()

            // Image formats (use cached data)
            pasteboard.setData(imageData.tiff, forType: .tiff)
            pasteboard.setData(imageData.png, forType: .png)

            // Plain text (Markdown)
            pasteboard.setString(markdown, forType: .string)

            // HTML
            pasteboard.setData(
                html.data(using: .utf8) ?? Data(),
                forType: .html
            )
        }
    }

    private static func imageData(for screenshot: ProcessedScreenshot) async -> (png: Data, tiff: Data) {
        let cachedPNG = screenshot.cachedPNGData()
        let cachedTIFF = screenshot.cachedTIFFData()
        if let cachedPNG, let cachedTIFF {
            return (cachedPNG, cachedTIFF)
        }

        let generated = await Task.detached(priority: .utility) {
            let png = screenshot.pngData
            let tiff = screenshot.tiffData
            return (png: png, tiff: tiff)
        }.value

        return generated
    }
}
