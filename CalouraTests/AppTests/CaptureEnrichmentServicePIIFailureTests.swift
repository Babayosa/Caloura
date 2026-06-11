import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureEnrichmentServicePIIFailureTests: XCTestCase {

    private struct StubError: Error {}

    func testPIIScanFailureSurfacesPiiScanFailedPhaseAndStatusMessage() async {
        let defaults = UserDefaults(
            suiteName: "com.caloura.tests.enrichment.\(#function)"
        )!
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        let settings = AppSettings(defaults: defaults)
        settings.autoDetectPII = true
        settings.semanticSearchEnabled = false
        settings.smartMetadataEnabled = false

        let temp = temporaryFileURL(prefix: "enrichment-pii")
        let appState = AppState(defaults: defaults, historyStoreURL: temp)
        let service = CaptureEnrichmentService(
            appState: appState,
            settings: settings,
            recognizeText: { _ in "non-empty so PII branch executes" },
            recognizeTextObservations: { _ in
                [
                    OCRObservation(
                        text: "non-empty so PII branch executes",
                        boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                        confidence: 1
                    )
                ]
            },
            detectPII: { _ in throw StubError() },
            enrichmentCoordinator: CaptureEnrichmentCoordinator()
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .piiScanFailed
        }

        XCTAssertEqual(appState.previewPhase(for: processed.id), .piiScanFailed)
        XCTAssertEqual(
            appState.statusMessage,
            "PII scan unavailable — capture stored unscanned."
        )
    }

    func testPIIScanDisabledStillReachesEnrichmentComplete() async {
        let defaults = UserDefaults(
            suiteName: "com.caloura.tests.enrichment.disabled.\(#function)"
        )!
        let settings = AppSettings(defaults: defaults)
        settings.autoDetectPII = false
        settings.semanticSearchEnabled = false
        settings.smartMetadataEnabled = false

        let temp = temporaryFileURL(prefix: "enrichment-disabled")
        let appState = AppState(defaults: defaults, historyStoreURL: temp)
        let service = CaptureEnrichmentService(
            appState: appState,
            settings: settings,
            recognizeText: { _ in "ocr text" },
            recognizeTextObservations: { _ in
                [
                    OCRObservation(
                        text: "ocr text",
                        boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                        confidence: 1
                    )
                ]
            },
            detectPII: { _ in throw StubError() },
            enrichmentCoordinator: CaptureEnrichmentCoordinator()
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }

        XCTAssertEqual(
            appState.previewPhase(for: processed.id),
            .enrichmentComplete,
            "PII scan disabled — enrichmentComplete should be emitted, not piiScanFailed"
        )
    }
}
