import Foundation
import XCTest
@testable import Caloura

@MainActor
final class CapturePipelineTests: XCTestCase {

    private func testImage() -> CGImage {
        TestImageFactory.makeTestImage(width: 100, height: 100)
    }

    // MARK: - performCapture

    func testPerformCapture_happyPath() async {
        var processImageCalled = false
        var copyToClipboardCalled = false
        var showQuickAccessCalled = false
        var notificationPosted = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            processImage: { cgImage, context, _ in
                processImageCalled = true
                return CapturePipelineTestHelpers.makeProcessed(
                    cgImage: cgImage, mode: context.mode
                )
            },
            copyToClipboard: { _, _ in copyToClipboardCalled = true },
            showQuickAccess: { _ in showQuickAccessCalled = true },
            postNotification: { _ in notificationPosted = true }
        )
        pipeline.settings.autoCopyToClipboard = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertTrue(processImageCalled)
        XCTAssertTrue(copyToClipboardCalled)
        XCTAssertTrue(showQuickAccessCalled)
        XCTAssertTrue(notificationPosted)
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    func testPerformCapture_permissionError() async {
        var permissionFailureCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: { permissionFailureCalled = true }
        )

        await pipeline.performCapture(mode: .area) {
            throw CaptureError.noPermission
        }

        XCTAssertTrue(permissionFailureCalled)
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    func testPerformCapture_genericError() async {
        var permissionFailureCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: { permissionFailureCalled = true }
        )

        await pipeline.performCapture(mode: .area) {
            throw CaptureError.captureFailed("test error")
        }

        XCTAssertFalse(permissionFailureCalled)
        XCTAssertTrue(
            pipeline.appState.statusMessage.contains("Try again")
        )
        XCTAssertFalse(pipeline.appState.statusMessage.contains("test error"))
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    func testPerformCapture_timeoutError() async {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function
        )

        await pipeline.performCapture(mode: .area) {
            throw TimeoutError.timedOut
        }

        XCTAssertTrue(pipeline.appState.statusMessage.contains("timed out"))
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    // MARK: - processCapture (via performCapture)

    func testProcessCapture_autoSaveOn() async {
        let saveExpectation = expectation(description: "saveFile called")

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                saveExpectation.fulfill()
                return URL(fileURLWithPath: "/tmp/saved.png")
            }
        )
        pipeline.settings.autoSaveToDisk = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        await fulfillment(of: [saveExpectation], timeout: 2.0)
    }

    func testProcessCapture_autoSaveOff() async {
        var saveFileCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                saveFileCalled = true
                return URL(fileURLWithPath: "/tmp/saved.png")
            }
        )
        pipeline.settings.autoSaveToDisk = false

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertFalse(saveFileCalled)
    }

    func testProcessCapture_saveFailure() async {
        let saveExpectation = expectation(description: "saveFile attempted")

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                saveExpectation.fulfill()
                throw NSError(
                    domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "disk full"]
                )
            }
        )
        pipeline.settings.autoSaveToDisk = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        await fulfillment(of: [saveExpectation], timeout: 2.0)
        // filePath stays nil because the save threw
        XCTAssertNil(pipeline.appState.lastScreenshot?.filePath)
    }

    // MARK: - distributeCapture (via performCapture)

    func testDistribute_autoCopyOn() async {
        var copyToClipboardCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            copyToClipboard: { _, _ in copyToClipboardCalled = true }
        )
        pipeline.settings.autoCopyToClipboard = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertTrue(copyToClipboardCalled)
    }

    func testDistribute_autoCopyOff() async {
        var copyToClipboardCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            copyToClipboard: { _, _ in copyToClipboardCalled = true }
        )
        pipeline.settings.autoCopyToClipboard = false

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertFalse(copyToClipboardCalled)
    }

    func testDistribute_playSoundOn() async {
        var playSoundCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            playSoundAction: { playSoundCalled = true }
        )
        pipeline.settings.playCaptureSound = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertTrue(playSoundCalled)
    }

    func testDistribute_playSoundOff() async {
        var playSoundCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            playSoundAction: { playSoundCalled = true }
        )
        pipeline.settings.playCaptureSound = false

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertFalse(playSoundCalled)
    }

    func testDistribute_setsLastScreenshotAndStatus() async {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function
        )

        XCTAssertNil(pipeline.appState.lastScreenshot)

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertNotNil(pipeline.appState.lastScreenshot)
        XCTAssertEqual(pipeline.appState.statusMessage, "Captured!")
    }

    // MARK: - addToHistoryWithOCR (via performCapture with autoSaveToDisk on)

    func testHistoryWithOCR_addsItem() async {
        let saveExpectation = expectation(description: "history save started")

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                saveExpectation.fulfill()
                return URL(fileURLWithPath: "/tmp/history-adds-item.png")
            }
        )
        pipeline.settings.autoSaveToDisk = true

        XCTAssertEqual(pipeline.appState.recentScreenshots.count, 0)

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        await fulfillment(of: [saveExpectation], timeout: 2.0)
        XCTAssertEqual(pipeline.appState.recentScreenshots.count, 1)
    }

    func testHistoryWithOCR_triggersOCR() async {
        let ocrExpectation = expectation(description: "OCR called")
        ocrExpectation.assertForOverFulfill = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            recognizeText: { _ in
                ocrExpectation.fulfill()
                return "recognized text"
            }
        )
        pipeline.settings.autoSaveToDisk = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        await fulfillment(of: [ocrExpectation], timeout: 5.0)
    }

    func testHistoryWithOCR_preservesEnrichmentForRapidCaptures() async {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            recognizeText: { cgImage in
                if cgImage.width == 101 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                return "text-\(cgImage.width)"
            }
        )

        let firstImage = TestImageFactory.makeTestImage(width: 101, height: 100)
        let secondImage = TestImageFactory.makeTestImage(width: 102, height: 100)
        let first = CapturePipelineTestHelpers.makeProcessed(cgImage: firstImage)
        let second = CapturePipelineTestHelpers.makeProcessed(cgImage: secondImage)

        pipeline.addToHistoryWithOCR(first)
        pipeline.addToHistoryWithOCR(second)

        await pollUntil(timeout: 2.0) {
            let items = pipeline.appState.recentScreenshots
            let firstText = items.first(where: { $0.id == first.id })?.ocrText
            let secondText = items.first(where: { $0.id == second.id })?.ocrText
            return firstText == "text-101" && secondText == "text-102"
        }

        XCTAssertEqual(
            pipeline.appState.recentScreenshots.first(where: { $0.id == first.id })?.ocrText,
            "text-101"
        )
        XCTAssertEqual(
            pipeline.appState.recentScreenshots.first(where: { $0.id == second.id })?.ocrText,
            "text-102"
        )
    }

    func testHistoryWithOCR_marksFailedPhaseOnOCRFailure() async {
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            recognizeText: { _ in
                throw NSError(
                    domain: "CapturePipelineTests",
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "ocr boom"]
                )
            }
        )
        let processed = CapturePipelineTestHelpers.makeProcessed()

        pipeline.addToHistoryWithOCR(processed)

        await pollUntil(timeout: 2.0) {
            pipeline.appState.previewPhase(for: processed.id) == .enrichmentFailed
        }

        XCTAssertEqual(
            pipeline.appState.previewPhase(for: processed.id),
            .enrichmentFailed
        )
    }

    func testCopyLastImage_usesSharedDistributionCopyPath() async {
        let copyExpectation = expectation(description: "copy called")
        var copiedModes: [CopyMode] = []

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            copyToClipboard: { _, mode in
                copiedModes.append(mode)
                copyExpectation.fulfill()
            }
        )
        let screenshot = CapturePipelineTestHelpers.makeProcessed()
        pipeline.appState.lastScreenshot = screenshot

        pipeline.copyLastImage()

        await fulfillment(of: [copyExpectation], timeout: 2.0)
        await pollUntil(timeout: 2.0) {
            pipeline.appState.statusMessage == "Copied image"
        }

        XCTAssertEqual(copiedModes, [.image])
        XCTAssertEqual(pipeline.appState.statusMessage, "Copied image")
    }

    func testSaveLastCapture_doesNotDoubleTriggerEnrichmentWhilePending() async {
        let saveExpectation = expectation(description: "save called twice")
        saveExpectation.expectedFulfillmentCount = 2
        let ocrExpectation = expectation(description: "OCR called once")
        ocrExpectation.assertForOverFulfill = true
        let defaults = CapturePipelineTestHelpers.makeDefaults(#function)
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-save-last-\(UUID().uuidString).json")
        let appState = AppState(defaults: defaults, historyStoreURL: historyURL)
        let settings = AppSettings(defaults: defaults)

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            settings: settings,
            appState: appState,
            saveCaptureAction: { screenshot in
                let url = URL(fileURLWithPath: "/tmp/\(screenshot.id.uuidString).png")
                screenshot.filePath = url
                screenshot.fileName = url.lastPathComponent
                appState.lastScreenshot = screenshot
                appState.syncProcessedScreenshot(screenshot)
                saveExpectation.fulfill()
                return url
            },
            recognizeText: { _ in
                ocrExpectation.fulfill()
                try? await Task.sleep(for: .milliseconds(250))
                return "recognized"
            }
        )
        let screenshot = CapturePipelineTestHelpers.makeProcessed()
        pipeline.appState.lastScreenshot = screenshot

        pipeline.saveLastCapture()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.previewPhase(for: screenshot.id) == .enrichmentPending
        }

        pipeline.saveLastCapture()

        await fulfillment(of: [saveExpectation, ocrExpectation], timeout: 2.0)
        await pollUntil(timeout: 3.0) {
            pipeline.appState.recentScreenshots.first(where: { $0.id == screenshot.id })?.ocrText == "recognized"
        }
    }

    func testCaptureRepeat_usesInjectedCaptureManager() async {
        let captureManager = FakeScreenCaptureManager()
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            captureManager: captureManager
        )
        pipeline.appState.lastCaptureRect = CGRect(x: 10, y: 10, width: 80, height: 60)
        pipeline.appState.lastCaptureScreen = nil

        pipeline.captureRepeat()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(captureManager.areaCalls, 1)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .area)
    }

    func testCaptureDelayed_windowDispatchesAfterCountdown() async {
        let expectedImage = TestImageFactory.makeTestImage(width: 170, height: 95)
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            selectWindowCapture: { _ in
                .selected { expectedImage }
            }
        )

        pipeline.captureDelayed(seconds: 1, mode: .window)

        await pollUntil(timeout: 3.0) {
            pipeline.appState.lastScreenshot != nil
                && !pipeline.appState.isCountingDown
        }

        XCTAssertEqual(pipeline.appState.lastScreenshot?.cgImage.width, expectedImage.width)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .window)
    }

    func testCaptureWindow_selectedPathUsesInjectedCaptureOperation() async {
        let expectedImage = TestImageFactory.makeTestImage(width: 150, height: 90)
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            selectWindowCapture: { _ in
                .selected { expectedImage }
            }
        )

        pipeline.captureWindow()

        await pollUntil(timeout: 2.0) {
            pipeline.appState.lastScreenshot != nil
        }

        XCTAssertEqual(pipeline.appState.lastScreenshot?.cgImage.width, expectedImage.width)
        XCTAssertEqual(pipeline.appState.lastScreenshot?.context.mode, .window)
    }

    func testCaptureWindow_failedToStartRoutesPermissionFailure() async {
        var permissionFailureCalled = false
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            handlePermissionFailure: { permissionFailureCalled = true },
            selectWindowCapture: { _ in .failedToStart }
        )

        pipeline.captureWindow()

        await pollUntil(timeout: 2.0) {
            permissionFailureCalled
        }

        XCTAssertTrue(permissionFailureCalled)
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    // MARK: - autoContextDetection preset routing

    func testAutoContext_on_usesCategory() async {
        var presetForCategoryCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            detectContext: {
                DetectedContext(appName: "Xcode", windowTitle: nil, category: .code)
            },
            presetForCategory: { _ in
                presetForCategoryCalled = true
                return CapturePreset(name: "Code Snippet")
            }
        )
        pipeline.settings.autoContextDetection = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertTrue(presetForCategoryCalled)
    }

    func testAutoContext_off_usesActivePreset() async {
        var presetByNameCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            presetByName: { _ in
                presetByNameCalled = true
                return CapturePreset(name: "Quick Capture")
            }
        )
        pipeline.settings.autoContextDetection = false

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertTrue(presetByNameCalled)
    }

    // MARK: - Pipeline Ordering (P3)

    func testQuickAccess_firesBeforeSave() async {
        var sequence = 0
        var quickAccessOrder = -1
        var saveOrder = -1
        let saveExpectation = expectation(description: "saveFile called")

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                sequence += 1
                saveOrder = sequence
                saveExpectation.fulfill()
                return URL(fileURLWithPath: "/tmp/ordering-test.png")
            },
            showQuickAccess: { _ in
                sequence += 1
                quickAccessOrder = sequence
            }
        )
        pipeline.settings.autoSaveToDisk = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }
        await fulfillment(of: [saveExpectation], timeout: 2.0)

        XCTAssertGreaterThan(quickAccessOrder, 0, "showQuickAccess should be called")
        XCTAssertGreaterThan(saveOrder, 0, "saveFile should be called")
        XCTAssertLessThan(
            quickAccessOrder, saveOrder,
            "showQuickAccess (\(quickAccessOrder)) must fire before saveFile (\(saveOrder))"
        )
    }

    func testQuickAccess_firesBeforeClipboardCopy() async {
        var sequence = 0
        var quickAccessOrder = -1
        var clipboardOrder = -1

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            copyToClipboard: { _, _ in
                sequence += 1
                clipboardOrder = sequence
            },
            showQuickAccess: { _ in
                sequence += 1
                quickAccessOrder = sequence
            }
        )
        pipeline.settings.autoCopyToClipboard = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertGreaterThan(quickAccessOrder, 0, "showQuickAccess should be called")
        XCTAssertGreaterThan(clipboardOrder, 0, "copyToClipboard should be called")
        XCTAssertLessThan(
            quickAccessOrder, clipboardOrder,
            "showQuickAccess (\(quickAccessOrder)) must fire before copyToClipboard (\(clipboardOrder))"
        )
    }

    func testPreviewPhase_transitionsFromPendingToComplete() async {
        let saveExpectation = expectation(description: "saveFile called")

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                saveExpectation.fulfill()
                return URL(fileURLWithPath: "/tmp/preview-phase.png")
            },
            recognizeText: { _ in
                try? await Task.sleep(nanoseconds: 150_000_000)
                return ""
            }
        )
        pipeline.settings.autoSaveToDisk = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }
        let screenshot = try? XCTUnwrap(pipeline.appState.lastScreenshot)

        await fulfillment(of: [saveExpectation], timeout: 2.0)
        if let screenshot {
            XCTAssertEqual(
                pipeline.appState.previewPhase(for: screenshot.id),
                .enrichmentPending
            )
            await pollUntil(timeout: 3.0) {
                pipeline.appState.previewPhase(for: screenshot.id) == .enrichmentComplete
            }
            XCTAssertEqual(
                pipeline.appState.previewPhase(for: screenshot.id),
                .enrichmentComplete
            )
        }
    }
}
