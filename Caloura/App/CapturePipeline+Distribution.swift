import AppKit
import Foundation

// MARK: - Distribution Actions

extension CapturePipeline {

    func performQuickAction(
        _ action: CaptureQuickAction,
        for screenshot: ProcessedScreenshot
    ) {
        distributionService.performQuickAction(action, for: screenshot)
    }

    func saveLastCapture() {
        distributionService.saveLastCapture()
    }

    func copyLastImage() {
        distributionService.copyLastImage()
    }

    func copyLastAsMarkdown() {
        distributionService.copyLastAsMarkdown()
    }

    func copyLastWithCitation() {
        distributionService.copyLastWithCitation()
    }

    func copyLastOCRText() {
        distributionService.copyLastOCRText()
    }
}
