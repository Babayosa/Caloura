import AppKit
import Foundation
import XCTest
@testable import Caloura

@MainActor
final class CaptureExecutionServiceTests: XCTestCase {
    private actor FlagBox {
        private var value = false

        func mark() {
            value = true
        }

        func read() -> Bool {
            value
        }
    }

    private struct Harness {
        let service: CaptureExecutionService
        let settings: AppSettings
        let appState: AppState
    }

    func testPerformCaptureHappyPathPublishesPreviewBeforeClipboard() async {
        var quickAccessOrder = 0
        var clipboardOrder = 0
        var eventOrder = 0

        let harness = makeService(
            testName: #function,
            copyToClipboard: { _, _ in
                eventOrder += 1
                clipboardOrder = eventOrder
            },
            showQuickAccess: { _ in
                eventOrder += 1
                quickAccessOrder = eventOrder
            }
        )
        harness.settings.autoCopyToClipboard = true

        await harness.service.performCapture(mode: CaptureMode.area) {
            TestImageFactory.makeTestImage(width: 120, height: 80)
        }

        XCTAssertEqual(harness.appState.statusMessage, "Captured!")
        XCTAssertNotNil(harness.appState.lastScreenshot)
        XCTAssertGreaterThan(quickAccessOrder, 0)
        XCTAssertGreaterThan(clipboardOrder, 0)
        XCTAssertLessThan(quickAccessOrder, clipboardOrder)
    }

    func testPerformCapturePermissionErrorRoutesPermissionFailure() async {
        var resumedMode: CaptureMode?

        let harness = makeService(
            testName: #function,
            handlePermissionFailure: { mode in
                resumedMode = mode
            }
        )

        await harness.service.performCapture(mode: CaptureMode.area) {
            throw CaptureError.noPermission
        }

        XCTAssertEqual(resumedMode, .area)
        XCTAssertFalse(harness.appState.isCapturing)
    }

    func testPerformCaptureGenericErrorPublishesSafeStatusMessage() async {
        let harness = makeService(testName: #function)

        await harness.service.performCapture(mode: CaptureMode.area) {
            throw CaptureError.captureFailed("test error")
        }

        XCTAssertTrue(harness.appState.statusMessage.contains("Try again"))
        XCTAssertFalse(harness.appState.statusMessage.contains("test error"))
        XCTAssertFalse(harness.appState.isCapturing)
    }

    func testHandleCaptureFailureResetsIsCapturingLocally() {
        // Regression pin for audit finding: handleCaptureFailure must own the
        // isCapturing reset itself. Today the flag is only rescued by the
        // safety net at the end of performCapture — one refactor away from a
        // stuck-true flag that wedges every future capture.
        let harness = makeService(testName: #function)
        harness.appState.isCapturing = true

        harness.service.handleCaptureFailure(
            CaptureError.captureFailed("test failure"),
            performanceSession: nil
        )

        XCTAssertFalse(
            harness.appState.isCapturing,
            "handleCaptureFailure must reset isCapturing in the handler itself, "
                + "not rely on the performCapture safety net"
        )
    }

    func testPerformCaptureDeferredSaveSchedulesEnrichmentAfterSave() async {
        let defaults = CapturePipelineTestHelpers.makeDefaults(#function)
        let settings = AppSettings(defaults: defaults)
        let historyStoreURL = temporaryFileURL(prefix: "execution-test-\(#function)")
        let appState = AppState(defaults: defaults, historyStoreURL: historyStoreURL)
        let saveExpectation = expectation(description: "save attempted")

        let harness = makeService(
            testName: #function,
            settings: settings,
            appState: appState,
            persistArtifact: { processed, _ in
                saveExpectation.fulfill()
                let url = URL(fileURLWithPath: "/tmp/direct-execution-save.png")
                processed.filePath = url
                processed.fileName = url.lastPathComponent
                appState.lastScreenshot = processed
                appState.syncProcessedScreenshot(processed)
            },
            recognizeText: { _ in "recognized text" }
        )
        harness.settings.autoSaveToDisk = true

        await harness.service.performCapture(mode: CaptureMode.area) {
            TestImageFactory.makeTestImage(width: 101, height: 90)
        }

        await fulfillment(of: [saveExpectation], timeout: 2.0)
        await pollUntil(timeout: 5.0) {
            harness.appState.recentScreenshots.first?.ocrText == "recognized text"
        }

        XCTAssertEqual(harness.appState.recentScreenshots.count, 1)
        XCTAssertEqual(harness.appState.recentScreenshots.first?.ocrText, "recognized text")
    }

    func testPerformCaptureDeferredSaveFailureDoesNotEnqueueEnrichmentOrHistory() async {
        let defaults = CapturePipelineTestHelpers.makeDefaults(#function)
        let settings = AppSettings(defaults: defaults)
        let historyStoreURL = temporaryFileURL(prefix: "execution-test-\(#function)")
        let appState = AppState(defaults: defaults, historyStoreURL: historyStoreURL)
        let recognizeTextCalled = FlagBox()

        let harness = makeService(
            testName: #function,
            settings: settings,
            appState: appState,
            persistArtifact: { _, _ in
                throw NSError(
                    domain: "tests",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "disk full"]
                )
            },
            recognizeText: { _ in
                await recognizeTextCalled.mark()
                return "recognized text"
            }
        )
        harness.settings.autoSaveToDisk = true

        await harness.service.performCapture(mode: CaptureMode.area) {
            TestImageFactory.makeTestImage(width: 101, height: 90)
        }

        await pollUntil(timeout: 2.0) {
            harness.appState.statusMessage == "Save failed: disk full"
                && !harness.appState.isCapturing
        }

        guard let screenshotID = harness.appState.lastScreenshot?.id else {
            return XCTFail("Expected raw preview screenshot")
        }
        let didRecognizeText = await recognizeTextCalled.read()
        XCTAssertFalse(didRecognizeText)
        XCTAssertEqual(harness.appState.recentScreenshots.count, 0)
        XCTAssertEqual(
            harness.appState.previewPhase(for: screenshotID),
            .rawPreviewReady
        )
    }

    private func makeService(
        testName: String,
        settings: AppSettings? = nil,
        appState: AppState? = nil,
        processImage: CapturePipeline.ProcessImageFn? = nil,
        persistArtifact: CapturePipeline.PersistArtifactFn? = nil,
        copyToClipboard: CapturePipeline.CopyToClipboardFn? = nil,
        recognizeText: CapturePipeline.RecognizeTextFn? = nil,
        handlePermissionFailure: CapturePipeline.HandlePermissionFailureFn? = nil,
        showQuickAccess: CapturePipeline.ShowQuickAccessFn? = nil,
        postNotification: CapturePipeline.PostNotificationFn? = nil
    ) -> Harness {
        let defaults = CapturePipelineTestHelpers.makeDefaults(testName)
        let resolvedSettings = settings ?? AppSettings(defaults: defaults)
        let historyStoreURL = temporaryFileURL(prefix: "execution-test-\(testName)")
        let resolvedAppState = appState ?? AppState(defaults: defaults, historyStoreURL: historyStoreURL)
        let requestResolver = makeRequestResolver(settings: resolvedSettings)
        let enrichmentService = makeEnrichmentService(
            appState: resolvedAppState,
            settings: resolvedSettings,
            recognizeText: recognizeText
        )
        let distributionService = makeDistributionService(
            appState: resolvedAppState,
            enrichmentService: enrichmentService,
            copyToClipboard: copyToClipboard
        )
        let service = CaptureExecutionService(
            settings: resolvedSettings,
            appState: resolvedAppState,
            requestResolver: requestResolver,
            distributionService: distributionService,
            enrichmentService: enrichmentService,
            capturePerformanceRecorder: CapturePerformanceRecorder(),
            processImage: processImage ?? { cgImage, context, _ in
                CapturePipelineTestHelpers.makeProcessed(cgImage: cgImage, mode: context.mode)
            },
            persistArtifact: persistArtifact ?? { processed, _ in
                let url = URL(fileURLWithPath: "/tmp/direct-persist.png")
                processed.filePath = url
                processed.fileName = url.lastPathComponent
                resolvedAppState.lastScreenshot = processed
                resolvedAppState.syncProcessedScreenshot(processed)
            },
            handlePermissionFailure: handlePermissionFailure ?? { _ in },
            showQuickAccess: showQuickAccess ?? { _ in },
            postNotification: postNotification ?? { _, _ in },
            metricsRecorder: CaptureMetricsRecorder()
        )
        return Harness(
            service: service,
            settings: resolvedSettings,
            appState: resolvedAppState
        )
    }

    private func makeRequestResolver(settings: AppSettings) -> CaptureRequestResolver {
        CaptureRequestResolver(
            settings: settings,
            detectContext: {
                DetectedContext(appName: "TestApp", windowTitle: "TestWindow", category: .other)
            },
            presetForCategory: { _ in nil },
            presetByName: { _ in nil }
        )
    }

    private func makeEnrichmentService(
        appState: AppState,
        settings: AppSettings,
        recognizeText: CapturePipeline.RecognizeTextFn?
    ) -> CaptureEnrichmentService {
        CaptureEnrichmentService(
            appState: appState,
            settings: settings,
            recognizeText: recognizeText ?? { _ in "" },
            recognizeTextObservations: { image in
                let text = try await (recognizeText ?? { _ in "" })(image)
                guard !text.isEmpty else { return [] }
                return [
                    OCRObservation(
                        text: text,
                        boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                        confidence: 1
                    )
                ]
            },
            enrichmentCoordinator: CaptureEnrichmentCoordinator()
        )
    }

    private func makeDistributionService(
        appState: AppState,
        enrichmentService: CaptureEnrichmentService,
        copyToClipboard: CapturePipeline.CopyToClipboardFn?
    ) -> CaptureDistributionService {
        CaptureDistributionService(
            appState: appState,
            copyToClipboard: copyToClipboard ?? { _, _ in },
            saveCapture: { screenshot in
                let url = URL(fileURLWithPath: "/tmp/direct-distribution-save.png")
                screenshot.filePath = url
                screenshot.fileName = url.lastPathComponent
                return url
            },
            playSound: { },
            enqueueEnrichment: { screenshot in
                enrichmentService.enqueueEnrichment(for: screenshot)
            },
            dispatchCommand: { _ in },
            showTip: { _ in },
            dismissQuickAccess: { }
        )
    }
}
