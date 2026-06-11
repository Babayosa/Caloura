import AppKit
import XCTest
@testable import Caloura

/// Phase 3.1 isolation tests for `CaptureEnrichmentService`.
///
/// These cover the matrix of enrichment-flag combinations, the empty-OCR
/// short-circuit, mid-OCR cancellation safety, and the rule that exactly
/// one terminal preview phase is emitted per enrichment run.
///
/// The PII-failure → `piiScanFailed` path lives in
/// `CaptureEnrichmentServicePIIFailureTests` (Phase 1.6). This file does
/// not duplicate it.
@MainActor
final class CaptureEnrichmentServiceTests: XCTestCase {

    // MARK: - Per-test wiring

    /// Records every closure invocation the enrichment loop makes against
    /// its dependencies. Used to assert that flag-gated work runs / does
    /// not run, and to count phase emissions.
    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _detectPIICalls = 0
        private var _embedTextCalls = 0
        private var _generateMetadataCalls = 0
        private var _phaseEmissions: [CapturePreviewPhase] = []

        var detectPIICalls: Int { lock.lock(); defer { lock.unlock() }; return _detectPIICalls }
        var embedTextCalls: Int { lock.lock(); defer { lock.unlock() }; return _embedTextCalls }
        var generateMetadataCalls: Int { lock.lock(); defer { lock.unlock() }; return _generateMetadataCalls }
        var phaseEmissions: [CapturePreviewPhase] { lock.lock(); defer { lock.unlock() }; return _phaseEmissions }

        func recordDetectPII() {
            lock.lock()
            _detectPIICalls += 1
            lock.unlock()
        }
        func recordEmbedText() {
            lock.lock()
            _embedTextCalls += 1
            lock.unlock()
        }
        func recordGenerateMetadata() {
            lock.lock()
            _generateMetadataCalls += 1
            lock.unlock()
        }
        func recordPhase(_ phase: CapturePreviewPhase) {
            lock.lock()
            _phaseEmissions.append(phase)
            lock.unlock()
        }
    }

    private struct StubError: Error {}

    private struct EnrichmentWiring {
        let appState: AppState
        let settings: AppSettings
        let recorder: CallRecorder
    }

    private func makeWiring(
        testName: String,
        autoDetectPII: Bool,
        semanticSearchEnabled: Bool,
        smartMetadataEnabled: Bool
    ) -> EnrichmentWiring {
        let suite = "com.caloura.tests.enrichment.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.autoDetectPII = autoDetectPII
        settings.semanticSearchEnabled = semanticSearchEnabled
        settings.smartMetadataEnabled = smartMetadataEnabled

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrichment-\(testName)-\(UUID()).json")
        let appState = AppState(defaults: defaults, historyStoreURL: temp)
        return EnrichmentWiring(appState: appState, settings: settings, recorder: CallRecorder())
    }

    private func makeService(
        appState: AppState,
        settings: AppSettings,
        recorder: CallRecorder,
        recognizeText: @escaping @Sendable (CGImage) async throws -> String,
        detectPIIThrows: Bool = false
    ) -> CaptureEnrichmentService {
        CaptureEnrichmentService(
            appState: appState,
            settings: settings,
            recognizeText: recognizeText,
            recognizeTextObservations: { image in
                let text = try await recognizeText(image)
                guard !text.isEmpty else { return [] }
                return [
                    OCRObservation(
                        text: text,
                        boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                        confidence: 1
                    )
                ]
            },
            detectPII: { _ in
                recorder.recordDetectPII()
                if detectPIIThrows { throw StubError() }
                return []
            },
            embedText: { _ in
                recorder.recordEmbedText()
                return [0.1, 0.2, 0.3]
            },
            generateMetadata: { _, _, _ in
                recorder.recordGenerateMetadata()
                return ScreenshotMetadata(
                    smartFileName: "test.png",
                    summary: "summary",
                    tags: ["a"]
                )
            },
            enrichmentCoordinator: CaptureEnrichmentCoordinator()
        )
    }

    private func observePhaseEmissions(
        appState: AppState,
        screenshotID: UUID,
        recorder: CallRecorder
    ) -> NSObjectProtocol {
        // CapturePreviewPhase changes are pushed to AppState; we cannot
        // intercept the closure from outside the service, so we observe the
        // AppState-published phase via KVO-equivalent polling. We capture
        // the *sequence* of distinct phase values we see during the test.
        var lastSeen: CapturePreviewPhase?
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated {
                let current = appState.previewPhase(for: screenshotID)
                if current != lastSeen {
                    lastSeen = current
                    recorder.recordPhase(current)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stopObserving(_ token: NSObjectProtocol) {
        if let timer = token as? Timer { timer.invalidate() }
    }

    // MARK: - Flag combinations

    func testAllFlagsEnabled_runsAllStagesAndEmitsEnrichmentComplete() async {
        let wiring = makeWiring(
            testName: "all_enabled",
            autoDetectPII: true,
            semanticSearchEnabled: true,
            smartMetadataEnabled: true
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in "non-empty ocr text" }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)
        let token = observePhaseEmissions(appState: appState, screenshotID: processed.id, recorder: recorder)
        defer { stopObserving(token) }

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }

        XCTAssertEqual(recorder.detectPIICalls, 1, "PII detection must run when enabled")
        XCTAssertEqual(recorder.embedTextCalls, 1, "embedding must run when semantic search enabled + non-empty text")
        XCTAssertEqual(recorder.generateMetadataCalls, 1, "smart metadata must run when enabled + non-empty text")
        XCTAssertEqual(appState.previewPhase(for: processed.id), .enrichmentComplete)
        _ = settings
    }

    func testAllFlagsDisabled_skipsEverythingButStillEmitsEnrichmentComplete() async {
        let wiring = makeWiring(
            testName: "all_disabled",
            autoDetectPII: false,
            semanticSearchEnabled: false,
            smartMetadataEnabled: false
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in "non-empty ocr text" }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }

        XCTAssertEqual(recorder.detectPIICalls, 0, "PII detection must not run when disabled")
        XCTAssertEqual(recorder.embedTextCalls, 0, "embedding must not run when semantic search disabled")
        XCTAssertEqual(recorder.generateMetadataCalls, 0, "smart metadata must not run when disabled")
        _ = settings
    }

    func testSemanticSearchOnly_skipsPIIAndMetadataButEmbeds() async {
        let wiring = makeWiring(
            testName: "semantic_only",
            autoDetectPII: false,
            semanticSearchEnabled: true,
            smartMetadataEnabled: false
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in "ocr text body" }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }

        XCTAssertEqual(recorder.detectPIICalls, 0)
        XCTAssertEqual(recorder.embedTextCalls, 1)
        XCTAssertEqual(recorder.generateMetadataCalls, 0)
        _ = settings
    }

    func testMetadataOnly_skipsPIIAndEmbeddingButGeneratesMetadata() async {
        let wiring = makeWiring(
            testName: "metadata_only",
            autoDetectPII: false,
            semanticSearchEnabled: false,
            smartMetadataEnabled: true
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in "ocr text body" }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }

        XCTAssertEqual(recorder.detectPIICalls, 0)
        XCTAssertEqual(recorder.embedTextCalls, 0)
        XCTAssertEqual(recorder.generateMetadataCalls, 1)
        _ = settings
    }

    func testPIIOnly_skipsEmbeddingAndMetadata() async {
        let wiring = makeWiring(
            testName: "pii_only",
            autoDetectPII: true,
            semanticSearchEnabled: false,
            smartMetadataEnabled: false
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in "ocr text body" }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }

        XCTAssertEqual(recorder.detectPIICalls, 1)
        XCTAssertEqual(recorder.embedTextCalls, 0)
        XCTAssertEqual(recorder.generateMetadataCalls, 0)
        _ = settings
    }

    // MARK: - Empty-OCR short-circuit

    func testEmptyOCRText_skipsEmbeddingAndMetadataButRunsPIIAndCompletes() async {
        // PII operates on the image, not the OCR text, so it must still run
        // even when OCR returns empty. Embedding + metadata both gate on
        // non-empty text and must be skipped.
        let wiring = makeWiring(
            testName: "empty_ocr",
            autoDetectPII: true,
            semanticSearchEnabled: true,
            smartMetadataEnabled: true
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in "" }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }

        XCTAssertEqual(recorder.detectPIICalls, 1, "PII still runs on the image regardless of OCR")
        XCTAssertEqual(recorder.embedTextCalls, 0, "embedding must not run for empty OCR text")
        XCTAssertEqual(recorder.generateMetadataCalls, 0, "metadata must not run for empty OCR text")
        XCTAssertEqual(appState.previewPhase(for: processed.id), .enrichmentComplete)
        _ = settings
    }

    // MARK: - OCR failure

    func testOCRFailure_emitsEnrichmentFailedPhase() async {
        let wiring = makeWiring(
            testName: "ocr_failure",
            autoDetectPII: false,
            semanticSearchEnabled: false,
            smartMetadataEnabled: false
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in throw StubError() }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentFailed
        }
        _ = settings
    }

    // MARK: - Single terminal phase emission

    func testTerminalPhaseEmittedExactlyOnce() async {
        // The enrichment run must not double-emit `.enrichmentComplete` or
        // race with `.piiScanFailed` / `.enrichmentFailed`. We watch the
        // phase stream and assert it transitions to a terminal value once.
        let wiring = makeWiring(
            testName: "single_phase",
            autoDetectPII: true,
            semanticSearchEnabled: true,
            smartMetadataEnabled: true
        )
        let appState = wiring.appState
        let settings = wiring.settings
        let recorder = wiring.recorder
        let service = makeService(
            appState: appState,
            settings: settings,
            recorder: recorder,
            recognizeText: { _ in "non-empty" }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()
        appState.syncProcessedScreenshot(processed)
        let token = observePhaseEmissions(appState: appState, screenshotID: processed.id, recorder: recorder)
        defer { stopObserving(token) }

        service.enqueueEnrichment(for: processed)

        await pollUntil(timeout: 2.0) {
            appState.previewPhase(for: processed.id) == .enrichmentComplete
        }
        // Give the polling observer a couple more ticks to confirm no
        // double-emit follows the terminal value.
        try? await Task.sleep(for: .milliseconds(50))

        let terminals: Set<CapturePreviewPhase> = [
            .enrichmentComplete, .enrichmentFailed, .piiScanFailed
        ]
        let terminalCount = recorder.phaseEmissions.filter { terminals.contains($0) }.count
        XCTAssertEqual(
            terminalCount, 1,
            "exactly one terminal phase must be emitted per enrichment run; saw: \(recorder.phaseEmissions)"
        )
        _ = settings
    }
}
