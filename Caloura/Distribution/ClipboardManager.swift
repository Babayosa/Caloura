import AppKit

struct ClipboardManager {
    private static let pasteboard = NSPasteboard.general

    // MARK: - Auto-Clear

    /// Active auto-clear timer task; cancelled when a new copy happens.
    @MainActor private static var autoClearTask: Task<Void, Never>?

    /// Schedule clipboard auto-clear after 60 seconds if the setting is enabled.
    /// Only clears if the pasteboard hasn't been modified by another app since we copied.
    @MainActor
    private static func scheduleAutoClearIfEnabled() {
        autoClearTask?.cancel()
        guard AppSettings.shared.autoClearClipboard else { return }
        let changeCount = pasteboard.changeCount
        autoClearTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
            guard !Task.isCancelled else { return }
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
            }
        }
    }

    /// Copy image to clipboard as TIFF + PNG
    static func copyImage(_ screenshot: ProcessedScreenshot) async {
        let imageData = await imageData(for: screenshot)
        await MainActor.run {
            pasteboard.clearContents()
            pasteboard.setData(imageData.tiff, forType: .tiff)
            pasteboard.setData(imageData.png, forType: .png)
            scheduleAutoClearIfEnabled()
        }
    }

    /// Copy as Markdown text: ![alt](filename)
    @MainActor
    static func copyAsMarkdown(_ screenshot: ProcessedScreenshot) {
        let markdown = MarkdownExporter.markdownImageTag(for: screenshot)
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        scheduleAutoClearIfEnabled()
    }

    /// Copy as Markdown with citation
    @MainActor
    static func copyWithCitation(_ screenshot: ProcessedScreenshot) {
        let citation = MarkdownExporter.markdownWithCitation(for: screenshot)
        pasteboard.clearContents()
        pasteboard.setString(citation, forType: .string)
        scheduleAutoClearIfEnabled()
    }

    /// Copy OCR text
    @MainActor
    static func copyOCRText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        scheduleAutoClearIfEnabled()
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

            scheduleAutoClearIfEnabled()
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
