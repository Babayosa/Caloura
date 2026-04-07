import AppKit

extension CapturePipeline {
    func makeCaptureEntrypointService() -> CaptureEntrypointService {
        CaptureEntrypointService(
            appState: appState,
            capturePerformanceRecorder: capturePerformanceRecorder,
            sessionState: sessionState,
            handlePermissionFailure: handlePermissionFailure,
            selectWindowCapture: selectWindowCapture,
            makeAreaCaptureSession: makeAreaCaptureSession,
            makeFullscreenCaptureSession: makeFullscreenCaptureSession,
            makeWindowCaptureSession: makeWindowCaptureSession,
            executionService: executionService,
            captureManager: captureManager,
            freezeService: freezeService,
            prewarmWindowContent: { [captureManager] in
                await captureManager.prewarmWindowShareableContent()
            },
            metricsRecorder: metricsRecorder,
            screenCountProvider: screenCountProvider,
            screensProvider: { NSScreen.screens },
            mainScreenProvider: { NSScreen.main },
            freezeScreensEnabled: freezeScreensEnabled,
            settings: settings
        )
    }
}
