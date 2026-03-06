import AppKit

enum ClipboardManagerError: LocalizedError {
    case pasteboardWriteFailed(String)
    case htmlEncodingFailed

    var errorDescription: String? {
        switch self {
        case .pasteboardWriteFailed(let item):
            return "Failed to write \(item) to the clipboard."
        case .htmlEncodingFailed:
            return "Failed to encode HTML clipboard content."
        }
    }
}

struct ClipboardManager {
    #if DEBUG
    @MainActor static var pasteboardOverride: NSPasteboard?
    @MainActor private static var activePasteboard: NSPasteboard {
        pasteboardOverride ?? .general
    }
    #else
    @MainActor private static var activePasteboard: NSPasteboard { .general }
    #endif

    // MARK: - Auto-Clear

    /// Active auto-clear timer task; cancelled when a new copy happens.
    @MainActor private static var autoClearTask: Task<Void, Never>?

    /// Schedule clipboard auto-clear after 60 seconds if the setting is enabled.
    /// Only clears if the pasteboard hasn't been modified by another app since we copied.
    @MainActor
    private static func scheduleAutoClearIfEnabled() {
        autoClearTask?.cancel()
        guard AppSettings.shared.autoClearClipboard else { return }
        let changeCount = activePasteboard.changeCount
        autoClearTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
            guard !Task.isCancelled else { return }
            if activePasteboard.changeCount == changeCount {
                activePasteboard.clearContents()
            }
        }
    }

    @MainActor
    static func copyNSImage(_ image: NSImage) throws {
        activePasteboard.clearContents()
        guard activePasteboard.writeObjects([image]) else {
            throw ClipboardManagerError.pasteboardWriteFailed("image")
        }
        scheduleAutoClearIfEnabled()
    }

    /// Copy image to clipboard as TIFF + PNG
    static func copyImage(_ screenshot: ProcessedScreenshot) async throws {
        let imageData = try await imageData(for: screenshot)
        try await MainActor.run {
            activePasteboard.clearContents()
            guard activePasteboard.setData(imageData.tiff, forType: .tiff) else {
                throw ClipboardManagerError.pasteboardWriteFailed("TIFF image")
            }
            guard activePasteboard.setData(imageData.png, forType: .png) else {
                throw ClipboardManagerError.pasteboardWriteFailed("PNG image")
            }
            scheduleAutoClearIfEnabled()
        }
    }

    /// Copy as Markdown text: ![alt](filename)
    @MainActor
    static func copyAsMarkdown(_ screenshot: ProcessedScreenshot) throws {
        let markdown = MarkdownExporter.markdownImageTag(for: screenshot)
        activePasteboard.clearContents()
        guard activePasteboard.setString(markdown, forType: .string) else {
            throw ClipboardManagerError.pasteboardWriteFailed("Markdown text")
        }
        scheduleAutoClearIfEnabled()
    }

    /// Copy as Markdown with citation
    @MainActor
    static func copyWithCitation(_ screenshot: ProcessedScreenshot) throws {
        let citation = MarkdownExporter.markdownWithCitation(for: screenshot)
        activePasteboard.clearContents()
        guard activePasteboard.setString(citation, forType: .string) else {
            throw ClipboardManagerError.pasteboardWriteFailed("citation text")
        }
        scheduleAutoClearIfEnabled()
    }

    /// Copy OCR text
    @MainActor
    static func copyOCRText(_ text: String) throws {
        activePasteboard.clearContents()
        guard activePasteboard.setString(text, forType: .string) else {
            throw ClipboardManagerError.pasteboardWriteFailed("OCR text")
        }
        scheduleAutoClearIfEnabled()
    }

    /// Copy multi-format: image + Markdown + HTML simultaneously
    /// Rich text editors get the image, plain text editors get markdown
    static func copyMultiFormat(_ screenshot: ProcessedScreenshot) async throws {
        let imageData = try await imageData(for: screenshot)
        let markdown = MarkdownExporter.markdownImageTag(for: screenshot)
        let html = MarkdownExporter.htmlImageTag(for: screenshot)
        guard let htmlData = html.data(using: .utf8) else {
            throw ClipboardManagerError.htmlEncodingFailed
        }
        try await MainActor.run {
            activePasteboard.clearContents()

            // Image formats (use cached data)
            guard activePasteboard.setData(imageData.tiff, forType: .tiff) else {
                throw ClipboardManagerError.pasteboardWriteFailed("TIFF image")
            }
            guard activePasteboard.setData(imageData.png, forType: .png) else {
                throw ClipboardManagerError.pasteboardWriteFailed("PNG image")
            }

            // Plain text (Markdown)
            guard activePasteboard.setString(markdown, forType: .string) else {
                throw ClipboardManagerError.pasteboardWriteFailed("Markdown text")
            }

            // HTML
            guard activePasteboard.setData(htmlData, forType: .html) else {
                throw ClipboardManagerError.pasteboardWriteFailed("HTML content")
            }

            scheduleAutoClearIfEnabled()
        }
    }

    private static func imageData(for screenshot: ProcessedScreenshot) async throws -> (png: Data, tiff: Data) {
        let cachedPNG = screenshot.cachedPNGData()
        let cachedTIFF = screenshot.cachedTIFFData()
        if let cachedPNG, let cachedTIFF {
            return (cachedPNG, cachedTIFF)
        }

        let generated = try await Task.detached(priority: .utility) {
            let png = try screenshot.pngData()
            let tiff = try screenshot.tiffData()
            return (png: png, tiff: tiff)
        }.value

        return generated
    }
}
