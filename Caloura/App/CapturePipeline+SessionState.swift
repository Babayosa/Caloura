import AppKit

extension CapturePipeline {
    private(set) var overlayWindows: [CaptureOverlayWindow] {
        get { sessionState.overlayWindows }
        set { sessionState.overlayWindows = newValue }
    }

    private(set) var screenOverlays: [ScreenSelectionOverlayWindow] {
        get { sessionState.screenOverlays }
        set { sessionState.screenOverlays = newValue }
    }

    private(set) var areaCaptureSession: (any AreaCaptureSessionHandling)? {
        get { sessionState.areaCaptureSession }
        set { sessionState.areaCaptureSession = newValue }
    }

    private(set) var fullscreenCaptureSession: (any FullscreenCaptureSessionHandling)? {
        get { sessionState.fullscreenCaptureSession }
        set { sessionState.fullscreenCaptureSession = newValue }
    }

    private(set) var delayedCaptureTask: Task<Void, Never>? {
        get { sessionState.delayedCaptureTask }
        set { sessionState.delayedCaptureTask = newValue }
    }

    func beginTrackedCaptureSession() -> UInt {
        sessionState.beginTrackedSession()
    }

    func isCurrentTrackedCaptureSession(_ sessionID: UInt) -> Bool {
        sessionState.isCurrentTrackedSession(sessionID)
    }

    func recordFirstMouseDownIfNeeded() -> Bool {
        sessionState.recordFirstMouseDownIfNeeded()
    }

    func replaceOverlayWindows(_ windows: [CaptureOverlayWindow]) {
        sessionState.overlayWindows = windows
    }

    func clearOverlayWindows() {
        sessionState.overlayWindows = []
    }

    func replaceScreenOverlays(_ overlays: [ScreenSelectionOverlayWindow]) {
        sessionState.screenOverlays = overlays
    }

    func clearScreenOverlays() {
        sessionState.screenOverlays = []
    }

    func replaceAreaCaptureSession(_ session: (any AreaCaptureSessionHandling)?) {
        sessionState.areaCaptureSession = session
    }

    func replaceFullscreenCaptureSession(_ session: (any FullscreenCaptureSessionHandling)?) {
        sessionState.fullscreenCaptureSession = session
    }

    func replaceDelayedCaptureTask(_ task: Task<Void, Never>?) {
        sessionState.replaceDelayedCaptureTask(task)
    }
}

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
            performAreaCapture: { [weak self] rect, screen, performanceSession in
                await self?.performAreaCapture(
                    rect: rect,
                    screen: screen,
                    performanceSession: performanceSession
                )
            },
            performFrozenAreaCapture: { [weak self] rect, screen, frozenImage, performanceSession in
                await self?.performFrozenAreaCapture(
                    rect: rect,
                    screen: screen,
                    frozenImage: frozenImage,
                    performanceSession: performanceSession
                )
            },
            performFullscreenCapture: { [weak self] screen, dismissDelay, performanceSession in
                await self?.performFullscreenCapture(
                    screen: screen,
                    dismissDelay: dismissDelay,
                    performanceSession: performanceSession
                )
            },
            performWindowCapture: { [weak self] capture, performanceSession in
                await self?.performWindowCapture(
                    capture: capture,
                    performanceSession: performanceSession
                )
            },
            freezeScreens: { [weak self] entryStart in
                await self?.freezeScreens(entryStart: entryStart) ?? [:]
            },
            prewarmWindowContent: { [captureManager] in
                await captureManager.prewarmWindowShareableContent()
            },
            captureScroll: { [weak self] in
                self?.captureScroll()
            },
            elapsedMilliseconds: elapsedMilliseconds(since:),
            recordMetric: { [weak self] stage, milliseconds in
                self?.recordMetric(stage: stage, milliseconds: milliseconds)
            },
            isSameObject: isSameObject,
            screenCountProvider: screenCountProvider,
            screensProvider: { NSScreen.screens },
            mainScreenProvider: { NSScreen.main },
            freezeScreensEnabled: freezeScreensEnabled
        )
    }
}
