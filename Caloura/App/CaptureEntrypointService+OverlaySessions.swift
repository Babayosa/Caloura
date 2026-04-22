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
        Self.logger.info(
            "Capture entry: first mouseDown at \(duration, privacy: .public) ms"
        )
        metricsRecorder.recordMetric(stage: .firstMouseDown, milliseconds: duration)
    }

    @discardableResult
    func presentAreaCaptureCoordinator(
        _ coordinator: any AreaCaptureSessionHandling,
        entryStart: CFAbsoluteTime,
        performanceSession: CapturePerformanceRecorder.Session
    ) -> Bool {
        let windows = sessionState.overlayWindowPool.acquire(
            cursorController: sessionState.cursorController
        )

        // No active screens (all displays disconnected mid-flow) leaves the
        // pipeline with no overlay to drive cancel/select callbacks. Without
        // this guard, isCapturing would stay stuck-true until app restart.
        guard !windows.isEmpty else {
            Self.logger.error("Capture entry: no active displays — aborting area capture")
            appState.statusMessage = "No active display — capture cancelled."
            sessionState.areaCaptureSession = nil
            finishInterruptedCapture(performanceSession)
            return false
        }

        let shouldSuppressDimming = freezeScreensEnabled && !settings.lowProfileCaptureEnabled
        coordinator.present(windows: windows, suppressDimming: shouldSuppressDimming)
        sessionState.overlayWindows = coordinator.overlayWindows

        let overlayVisibleDuration = metricsRecorder.elapsedMilliseconds(since: entryStart)
        Self.logger.info(
            "Capture entry: overlay visible at \(overlayVisibleDuration, privacy: .public) ms"
        )
        metricsRecorder.recordMetric(stage: .overlayVisible, milliseconds: overlayVisibleDuration)
        return true
    }

    func loadAreaCaptureFrozenImages(
        for coordinator: any AreaCaptureSessionHandling,
        sessionID: UInt,
        entryStart: CFAbsoluteTime,
        performanceSession: CapturePerformanceRecorder.Session
    ) {
        Task { @MainActor [weak self, weak coordinator] in
            guard let self else { return }
            let frozenImages = await self.freezeService.freezeScreens(
                entryStart: entryStart,
                performanceSession: performanceSession
            )

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
