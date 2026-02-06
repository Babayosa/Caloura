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
            pipeline.appState.statusMessage.contains("Capture failed")
        )
        XCTAssertFalse(pipeline.appState.isCapturing)
    }

    // MARK: - processCapture (via performCapture)

    func testProcessCapture_autoSaveOn() async {
        var saveFileCalled = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                saveFileCalled = true
                return URL(fileURLWithPath: "/tmp/saved.png")
            }
        )
        pipeline.settings.autoSaveToDisk = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertTrue(saveFileCalled)
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
        var saveFileThrew = false

        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function,
            saveFile: { _, _, _, _ in
                saveFileThrew = true
                throw NSError(
                    domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "disk full"]
                )
            }
        )
        pipeline.settings.autoSaveToDisk = true

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

        XCTAssertTrue(saveFileThrew)
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
        let pipeline = CapturePipelineTestHelpers.makePipeline(
            testName: #function
        )
        pipeline.settings.autoSaveToDisk = true

        XCTAssertEqual(pipeline.appState.recentScreenshots.count, 0)

        let img = testImage()
        await pipeline.performCapture(mode: .area) { img }

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
}
