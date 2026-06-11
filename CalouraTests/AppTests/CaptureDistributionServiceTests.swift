import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureDistributionServiceTests: XCTestCase {

    func testPerformQuickActionSave_skipsEnrichmentWhenPreviewAlreadyPending() async {
        let saveCalled = expectation(description: "save called")
        let appState = makeAppState(
            testName: #function,
            historyURL: temporaryFileURL(prefix: "distribution-\(#function)")
        )
        let screenshot = makeScreenshot()
        appState.setCapturePreviewPhase(.enrichmentPending, for: screenshot.id)
        var enrichmentCalls = 0

        let service = CaptureDistributionService(
            appState: appState,
            copyToClipboard: { _, _ in },
            saveCapture: { screenshot in
                saveCalled.fulfill()
                return URL(fileURLWithPath: "/tmp/\(screenshot.id.uuidString).png")
            },
            playSound: { },
            enqueueEnrichment: { _ in enrichmentCalls += 1 },
            dispatchCommand: { _ in },
            showTip: { _ in },
            dismissQuickAccess: { }
        )

        service.performQuickAction(.save, for: screenshot)

        await fulfillment(of: [saveCalled], timeout: 1.0)
        await pollUntil(timeout: 1.0) {
            appState.statusMessage == "Saved to disk"
        }

        XCTAssertEqual(enrichmentCalls, 0)
        XCTAssertEqual(
            appState.previewPhase(for: screenshot.id),
            .enrichmentPending
        )
    }

    func testSaveLastCapture_skipsEnrichmentWhenScreenshotAlreadyHasOCRText() async {
        let saveCalled = expectation(description: "save called")
        let appState = makeAppState(
            testName: #function,
            historyURL: temporaryFileURL(prefix: "distribution-\(#function)")
        )
        let screenshot = makeScreenshot(ocrText: "recognized text")
        appState.lastScreenshot = screenshot
        var enrichmentCalls = 0

        let service = CaptureDistributionService(
            appState: appState,
            copyToClipboard: { _, _ in },
            saveCapture: { screenshot in
                saveCalled.fulfill()
                return URL(fileURLWithPath: "/tmp/\(screenshot.id.uuidString).png")
            },
            playSound: { },
            enqueueEnrichment: { _ in enrichmentCalls += 1 },
            dispatchCommand: { _ in },
            showTip: { _ in },
            dismissQuickAccess: { }
        )

        service.saveLastCapture()

        await fulfillment(of: [saveCalled], timeout: 1.0)
        await pollUntil(timeout: 1.0) {
            appState.statusMessage == "Saved to disk"
        }

        XCTAssertEqual(enrichmentCalls, 0)
        XCTAssertEqual(
            appState.previewPhase(for: screenshot.id),
            .rawPreviewReady
        )
    }
}

@MainActor
private func makeAppState(testName: String, historyURL: URL) -> AppState {
    let defaults = CapturePipelineTestHelpers.makeDefaults(testName)
    return AppState(defaults: defaults, historyStoreURL: historyURL)
}

private func makeScreenshot(ocrText: String? = nil) -> ProcessedScreenshot {
    let cgImage = TestImageFactory.makeTestImage(width: 120, height: 80)
    let nsImage = NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
    )
    return ProcessedScreenshot(
        image: nsImage,
        cgImage: cgImage,
        context: CaptureContext(mode: .area),
        ocrText: ocrText
    )
}
