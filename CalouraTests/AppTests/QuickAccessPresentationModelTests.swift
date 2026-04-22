import XCTest
@testable import Caloura

final class QuickAccessPresentationModelTests: XCTestCase {

    func testUnsavedScreenshotKeepsBeautifyInOverflow() {
        let screenshot = CapturePipelineTestHelpers.makeProcessed()

        let presentation = QuickAccessPresentationModel(
            screenshot: screenshot,
            previewPhase: .rawPreviewReady,
            piiResult: nil
        )

        XCTAssertEqual(
            presentation.primaryActions,
            [.copy, .save, .annotate]
        )
        XCTAssertEqual(
            presentation.overflowActions,
            [.pin, .beautify, .redact, .markdown, .citation, .dismiss]
        )
        XCTAssertFalse(presentation.showsPendingBadge)
        XCTAssertFalse(presentation.showsPIIBadge)
    }

    func testSavedScreenshotWithPIIPrefersPinAndRedact() {
        let screenshot = CapturePipelineTestHelpers.makeProcessed()
        screenshot.filePath = URL(fileURLWithPath: "/tmp/example.png")
        screenshot.fileName = "example.png"

        let pii = PIIDetectionResult(
            detections: [
                PIIDetection(
                    type: .email,
                    rawMatch: "user@example.com",
                    boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                    confidence: 0.9
                )
            ],
            screenshotID: screenshot.id
        )

        let presentation = QuickAccessPresentationModel(
            screenshot: screenshot,
            previewPhase: .enrichmentComplete,
            piiResult: pii
        )

        XCTAssertEqual(
            presentation.primaryActions,
            [.copy, .pin, .annotate, .redact]
        )
        XCTAssertEqual(
            presentation.overflowActions,
            [.save, .beautify, .markdown, .citation, .dismiss]
        )
        XCTAssertTrue(presentation.showsPIIBadge)
        XCTAssertFalse(presentation.showsPendingBadge)
    }

    func testPendingEnrichmentShowsProgressBadge() {
        let screenshot = CapturePipelineTestHelpers.makeProcessed()

        let presentation = QuickAccessPresentationModel(
            screenshot: screenshot,
            previewPhase: .enrichmentPending,
            piiResult: nil
        )

        XCTAssertTrue(presentation.showsPendingBadge)
    }
}
