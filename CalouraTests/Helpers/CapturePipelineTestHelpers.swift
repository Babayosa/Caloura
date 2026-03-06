import AppKit
import Foundation
@testable import Caloura

/// Shared test helpers for CapturePipeline tests.
enum CapturePipelineTestHelpers {

    /// Creates a clean `UserDefaults` suite for isolated pipeline tests.
    static func makeDefaults(_ testName: String) -> UserDefaults {
        let suite = "com.caloura.tests.pipeline.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Creates a `ProcessedScreenshot` from a test CGImage.
    static func makeProcessed(
        cgImage: CGImage? = nil,
        mode: CaptureMode = .area
    ) -> ProcessedScreenshot {
        let img = cgImage ?? TestImageFactory.makeTestImage()
        let nsImage = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        return ProcessedScreenshot(
            image: nsImage,
            cgImage: img,
            context: CaptureContext(mode: mode)
        )
    }

    /// Creates a test CapturePipeline with default no-op closures.
    /// Override only the closures relevant to each test.
    @MainActor
    static func makePipeline(
        testName: String,
        settings: AppSettings? = nil,
        appState: AppState? = nil,
        captureManager: ScreenCaptureManaging? = nil,
        capturePerformanceRecorder: CapturePerformanceRecorder? = nil,
        detectContext: CapturePipeline.DetectContextFn? = nil,
        processImage: CapturePipeline.ProcessImageFn? = nil,
        saveFile: CapturePipeline.SaveFileFn? = nil,
        persistArtifact: CapturePipeline.PersistArtifactFn? = nil,
        copyToClipboard: CapturePipeline.CopyToClipboardFn? = nil,
        recognizeText: CapturePipeline.RecognizeTextFn? = nil,
        handlePermissionFailure: CapturePipeline.HandlePermissionFailureFn? = nil,
        showQuickAccess: CapturePipeline.ShowQuickAccessFn? = nil,
        playSoundAction: CapturePipeline.PlaySoundFn? = nil,
        postNotification: CapturePipeline.PostNotificationFn? = nil,
        presetForCategory: CapturePipeline.PresetForCategoryFn? = nil,
        presetByName: CapturePipeline.PresetByNameFn? = nil,
        selectWindowCapture: CapturePipeline.SelectWindowCaptureFn? = nil,
        makeAreaCaptureSession: CapturePipeline.MakeAreaCaptureSessionFn? = nil,
        makeFullscreenCaptureSession: CapturePipeline.MakeFullscreenCaptureSessionFn? = nil,
        makeWindowCaptureSession: CapturePipeline.MakeWindowCaptureSessionFn? = nil,
        screenCountProvider: @escaping () -> Int = { NSScreen.screens.count },
        freezeScreensEnabled: Bool = true,
        enrichmentCoordinator: CaptureEnrichmentCoordinator = CaptureEnrichmentCoordinator()
    ) -> CapturePipeline {
        let defaults = makeDefaults(testName)
        let testSettings = settings ?? AppSettings(defaults: defaults)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-test-\(testName)-\(UUID().uuidString).json")
        let testAppState = appState ?? AppState(defaults: defaults, historyStoreURL: tempURL)
        let recorder = capturePerformanceRecorder ?? CapturePerformanceRecorder()

        return CapturePipeline(
            settings: testSettings,
            appState: testAppState,
            captureManager: captureManager,
            capturePerformanceRecorder: recorder,
            detectContext: detectContext ?? {
                DetectedContext(appName: "TestApp", windowTitle: "TestWindow", category: .other)
            },
            processImage: processImage ?? { cgImage, context, _ in
                makeProcessed(cgImage: cgImage, mode: context.mode)
            },
            saveFile: saveFile ?? { _, _, _, _ in
                URL(fileURLWithPath: "/tmp/test-save.png")
            },
            persistArtifact: persistArtifact ?? { processed, preset in
                let url = try await (saveFile ?? { _, _, _, _ in
                    URL(fileURLWithPath: "/tmp/test-save.png")
                })(
                    processed,
                    testSettings.saveDirectory,
                    preset.subfolder,
                    testSettings.imageFormat
                )
                processed.filePath = url
                processed.fileName = url.lastPathComponent
                testAppState.lastScreenshot = processed
                testAppState.syncProcessedScreenshot(processed)
            },
            copyToClipboard: copyToClipboard ?? { _, _ in },
            recognizeText: recognizeText ?? { _ in "" },
            handlePermissionFailure: handlePermissionFailure ?? { @MainActor in },
            showQuickAccess: showQuickAccess ?? { _ in },
            playSoundAction: playSoundAction ?? { },
            postNotification: postNotification ?? { _ in },
            presetForCategory: presetForCategory ?? { _ in nil },
            presetByName: presetByName ?? { _ in nil },
            selectWindowCapture: selectWindowCapture ?? { _ in .cancelled },
            makeAreaCaptureSession: makeAreaCaptureSession,
            makeFullscreenCaptureSession: makeFullscreenCaptureSession,
            makeWindowCaptureSession: makeWindowCaptureSession,
            screenCountProvider: screenCountProvider,
            freezeScreensEnabled: freezeScreensEnabled,
            enrichmentCoordinator: enrichmentCoordinator
        )
    }
}
