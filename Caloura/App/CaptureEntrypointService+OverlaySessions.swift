import AppKit
import ScreenCaptureKit

extension CaptureEntrypointService {
    func makeAreaCaptureCoordinator(
        sessionID: UInt,
        entryStart: CFAbsoluteTime,
        performanceSession: CapturePerformanceRecorder.Session
    ) -> any AreaCaptureSessionHandling {
        makeAreaCaptureSession(
            performanceSession,
            { [weak self] rect, screen, frozenImage in
                guard let self else { return }
                await self.handleAreaCaptureSelection(
                    sessionID: sessionID,
                    rect: rect,
                    screen: screen,
                    frozenImage: frozenImage,
                    performanceSession: performanceSession
                )
            },
            { [weak self] in
                self?.handleAreaCaptureCancellation(
                    sessionID: sessionID,
                    performanceSession: performanceSession
                )
            },
            { [weak self] in
                self?.recordAreaCaptureFirstMouseDown(entryStart: entryStart)
            }
        )
    }

    func handleAreaCaptureSelection(
        sessionID: UInt,
        rect: CGRect,
        screen: NSScreen,
        frozenImage: CGImage?,
        performanceSession: CapturePerformanceRecorder.Session
    ) async {
        guard sessionState.isCurrentTrackedSession(sessionID) else { return }
        sessionState.overlayWindowPool.release()
        sessionState.overlayWindows = []
        sessionState.areaCaptureSession = nil
        appState.lastCaptureRect = rect
        appState.lastCaptureScreen = screen

        if let frozenImage {
            await performFrozenAreaCapture(
                rect: rect,
                screen: screen,
                frozenImage: frozenImage,
                performanceSession: performanceSession
            )
            return
        }

        await performAreaCapture(rect: rect, screen: screen, performanceSession: performanceSession)
    }

    func handleAreaCaptureCancellation(
        sessionID: UInt,
        performanceSession: CapturePerformanceRecorder.Session
    ) {
        guard sessionState.isCurrentTrackedSession(sessionID) else { return }
        sessionState.overlayWindowPool.release()
        sessionState.overlayWindows = []
        sessionState.areaCaptureSession = nil
        finishInterruptedCapture(performanceSession)
    }

    func recordAreaCaptureFirstMouseDown(entryStart: CFAbsoluteTime) {
        guard sessionState.recordFirstMouseDownIfNeeded() else { return }
        let duration = metricsRecorder.elapsedMilliseconds(since: entryStart)
        captureEntryLogger.info(
            "Capture entry: first mouseDown at \(duration, privacy: .public) ms"
        )
        metricsRecorder.recordMetric(stage: .firstMouseDown, milliseconds: duration)
    }

    func presentAreaCaptureCoordinator(
        _ coordinator: any AreaCaptureSessionHandling,
        entryStart: CFAbsoluteTime
    ) {
        let windows = sessionState.overlayWindowPool.acquire(
            cursorController: sessionState.cursorController
        )
        let shouldSuppressDimming = freezeScreensEnabled && !settings.lowProfileCaptureEnabled
        coordinator.present(windows: windows, suppressDimming: shouldSuppressDimming)
        sessionState.overlayWindows = coordinator.overlayWindows

        let overlayVisibleDuration = metricsRecorder.elapsedMilliseconds(since: entryStart)
        captureEntryLogger.info(
            "Capture entry: overlay visible at \(overlayVisibleDuration, privacy: .public) ms"
        )
        metricsRecorder.recordMetric(stage: .overlayVisible, milliseconds: overlayVisibleDuration)
    }

    func loadAreaCaptureFrozenImages(
        for coordinator: any AreaCaptureSessionHandling,
        sessionID: UInt,
        entryStart: CFAbsoluteTime
    ) {
        Task { @MainActor [weak self, weak coordinator] in
            guard let self else { return }
            let frozenImages = await self.freezeService.freezeScreens(entryStart: entryStart)

            guard self.sessionState.isCurrentTrackedSession(sessionID),
                  self.sessionState.areaCaptureSession as AnyObject? === coordinator as AnyObject? else {
                return
            }

            coordinator?.updateFrozenImages(frozenImages)
        }
    }

    func makeFullscreenCaptureCoordinator(
        performanceSession: CapturePerformanceRecorder.Session
    ) -> any FullscreenCaptureSessionHandling {
        makeFullscreenCaptureSession(
            performanceSession,
            { [weak self] selectedScreen in
                guard let self else { return }
                self.sessionState.screenOverlays = []
                self.sessionState.fullscreenCaptureSession = nil
                await self.performFullscreenCapture(
                    screen: selectedScreen,
                    dismissDelay: true,
                    performanceSession: performanceSession
                )
            },
            { [weak self] in
                guard let self else { return }
                self.sessionState.screenOverlays = []
                self.sessionState.fullscreenCaptureSession = nil
                self.finishInterruptedCapture(performanceSession)
            }
        )
    }
}
