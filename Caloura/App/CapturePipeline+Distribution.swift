import Foundation

// MARK: - Distribution Actions

extension CapturePipeline {

    func copyLastAsMarkdown() {
        guard let screenshot = appState.lastScreenshot else { return }
        ClipboardManager.copyAsMarkdown(screenshot)
        appState.statusMessage = "Copied as Markdown"
    }

    func copyLastWithCitation() {
        guard let screenshot = appState.lastScreenshot else { return }
        ClipboardManager.copyWithCitation(screenshot)
        appState.statusMessage = "Copied with citation"
    }

    func copyLastOCRText() {
        guard let lastItem = appState.recentScreenshots.first,
              let text = lastItem.ocrText, !text.isEmpty else {
            appState.statusMessage = "No OCR text available"
            return
        }
        ClipboardManager.copyOCRText(text)
        appState.statusMessage = "Copied OCR text"
    }
}
