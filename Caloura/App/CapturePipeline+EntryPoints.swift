import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")
private let entryLogger = Logger(subsystem: "com.caloura.app", category: "CaptureEntry")

// MARK: - Capture Entry Points

extension CapturePipeline {

    // MARK: Perform Captures

    func performAreaCapture(
        rect: CGRect,
        screen: NSScreen,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await performCapture(mode: .area, performanceSession: performanceSession) {
            try await self.captureManager.captureArea(
                rect: rect, screen: screen
            )
        }
    }

    /// Crop from an already-captured frozen image (for freeze capture mode)
    func performFrozenAreaCapture(
        rect: CGRect,
        screen: NSScreen,
        frozenImage: CGImage,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await performCapture(mode: .area, performanceSession: performanceSession) {
            // Convert screen coordinates to image coordinates
            let scale = screen.backingScaleFactor
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - rect.origin.y - rect.height

            // Calculate crop rect relative to this screen's image
            let imageRect = CGRect(
                x: rect.origin.x * scale,
                y: flippedY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral

            guard let croppedImage = frozenImage.cropping(to: imageRect) else {
                throw CaptureError.captureFailed(
                    "Failed to crop frozen image"
                )
            }
            return croppedImage
        }
    }

    func performFullscreenCapture(
        screen: NSScreen? = nil,
        dismissDelay: Bool = false,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        if dismissDelay {
            // Brief delay to let menu bar close / overlays dismiss
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        await performCapture(
            mode: .fullscreen,
            performanceSession: performanceSession
        ) {
            try await self.captureManager.captureFullScreen(screen: screen)
        }
    }

    func performWindowCapture(
        capture: @escaping @MainActor () async throws -> CGImage,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await performCapture(mode: .window, performanceSession: performanceSession) {
            try await capture()
        }
    }

    // MARK: Entry Points

    func captureArea() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true
        captureSessionID &+= 1
        let sessionID = captureSessionID
        let entryStart = CFAbsoluteTimeGetCurrent()
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .area)
        entryLogger.debug("Capture entry: request received")
        firstMouseDownLogged = false

        let coordinator = makeAreaCaptureCoordinator(
            sessionID: sessionID,
            entryStart: entryStart,
            performanceSession: performanceSession
        )
        areaCaptureSession?.dismiss()
        replaceAreaCaptureSession(coordinator)

        presentAreaCaptureCoordinator(coordinator, entryStart: entryStart)

        guard freezeScreensEnabled else { return }
        loadAreaCaptureFrozenImages(
            for: coordinator,
            sessionID: sessionID,
            entryStart: entryStart
        )
    }

    private func makeAreaCaptureCoordinator(
        sessionID: UInt,
        entryStart: CFAbsoluteTime,
        performanceSession: CapturePerformanceRecorder.Session
    ) -> any AreaCaptureSessionHandling {
        makeAreaCaptureSession(
            performanceSession,
            { [weak self] (rect: CGRect, screen: NSScreen, frozenImage: CGImage?) in
                guard let self = self else { return }
                await self.handleAreaCaptureSelection(
                    sessionID: sessionID,
                    rect: rect,
                    screen: screen,
                    frozenImage: frozenImage,
                    performanceSession: performanceSession
                )
            },
            { [weak self] in
                guard let self = self else { return }
                self.handleAreaCaptureCancellation(
                    sessionID: sessionID,
                    performanceSession: performanceSession
                )
            },
            { [weak self] in
                self?.recordAreaCaptureFirstMouseDown(entryStart: entryStart)
            }
        )
    }

    private func handleAreaCaptureSelection(
        sessionID: UInt,
        rect: CGRect,
        screen: NSScreen,
        frozenImage: CGImage?,
        performanceSession: CapturePerformanceRecorder.Session
    ) async {
        guard captureSessionID == sessionID else { return }
        clearOverlayWindows()
        replaceAreaCaptureSession(nil)
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

        await performAreaCapture(
            rect: rect,
            screen: screen,
            performanceSession: performanceSession
        )
    }

    private func handleAreaCaptureCancellation(
        sessionID: UInt,
        performanceSession: CapturePerformanceRecorder.Session
    ) {
        guard captureSessionID == sessionID else { return }
        clearOverlayWindows()
        replaceAreaCaptureSession(nil)
        appState.isCapturing = false
        capturePerformanceRecorder.finishSession(performanceSession)
    }

    private func recordAreaCaptureFirstMouseDown(entryStart: CFAbsoluteTime) {
        guard !firstMouseDownLogged else { return }
        firstMouseDownLogged = true
        let duration = elapsedMilliseconds(since: entryStart)
        entryLogger.info(
            "Capture entry: first mouseDown at \(duration, privacy: .public) ms"
        )
        recordMetric(stage: .firstMouseDown, milliseconds: duration)
    }

    private func presentAreaCaptureCoordinator(
        _ coordinator: any AreaCaptureSessionHandling,
        entryStart: CFAbsoluteTime
    ) {
        coordinator.present(suppressDimming: freezeScreensEnabled)
        replaceOverlayWindows(coordinator.overlayWindows)

        let overlayVisibleDuration = elapsedMilliseconds(since: entryStart)
        entryLogger.info(
            "Capture entry: overlay visible at \(overlayVisibleDuration, privacy: .public) ms"
        )
        recordMetric(
            stage: .overlayVisible,
            milliseconds: overlayVisibleDuration
        )
    }

    private func loadAreaCaptureFrozenImages(
        for coordinator: any AreaCaptureSessionHandling,
        sessionID: UInt,
        entryStart: CFAbsoluteTime
    ) {
        Task { [weak self, weak coordinator] in
            guard let self = self else { return }
            let frozenImages = await self.freezeScreens(entryStart: entryStart)

            guard self.captureSessionID == sessionID,
                  self.isSameObject(
                    self.areaCaptureSession as AnyObject?,
                    coordinator as AnyObject?
                  ) else {
                return
            }

            coordinator?.updateFrozenImages(frozenImages)
        }
    }

    func captureFullscreen() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .fullscreen)

        if screenCountProvider() > 1 {
            let coordinator = makeFullscreenCaptureSession(
                performanceSession,
                { [weak self] (selectedScreen: NSScreen) in
                    guard let self = self else { return }
                    self.clearScreenOverlays()
                    self.replaceFullscreenCaptureSession(nil)
                    await self.performFullscreenCapture(
                        screen: selectedScreen,
                        dismissDelay: true,
                        performanceSession: performanceSession
                    )
                },
                { [weak self] in
                    guard let self = self else { return }
                    self.clearScreenOverlays()
                    self.replaceFullscreenCaptureSession(nil)
                    self.appState.isCapturing = false
                    self.capturePerformanceRecorder.finishSession(performanceSession)
                }
            )
            fullscreenCaptureSession?.dismiss()
            replaceFullscreenCaptureSession(coordinator)
            coordinator.present()
            replaceScreenOverlays(coordinator.overlayWindows)
        } else {
            capturePerformanceRecorder.mark(.appActivated, in: performanceSession)
            Task {
                await performFullscreenCapture(
                    performanceSession: performanceSession
                )
            }
        }
    }

    func captureWindow() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .window)
        NSApp.activate(ignoringOtherApps: true)

        Task {
            let coordinator = makeWindowCaptureSession(
                performanceSession,
                { [captureManager] in
                    await captureManager.prewarmWindowShareableContent()
                },
                selectWindowCapture
            )
            switch await coordinator.pick() {
            case .selected(let captureOperation):
                await performWindowCapture(
                    capture: captureOperation,
                    performanceSession: performanceSession
                )
            case .cancelled:
                appState.isCapturing = false
                capturePerformanceRecorder.finishSession(performanceSession)
            case .failedToStart:
                appState.isCapturing = false
                capturePerformanceRecorder.finishSession(performanceSession)
                await handlePermissionFailure()
            }
        }
    }

    /// Re-capture the exact same region as the last area capture.
    func captureRepeat() {
        guard let rect = appState.lastCaptureRect else {
            appState.statusMessage = "No previous area capture to repeat."
            return
        }
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        // Validate the stored screen is still connected (M21).
        if let screen = appState.lastCaptureScreen,
           !NSScreen.screens.contains(where: { $0 == screen }) {
            appState.lastCaptureScreen = nil
        }
        let screen = appState.lastCaptureScreen ?? NSScreen.main
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .area)

        Task {
            await performCapture(mode: .area, performanceSession: performanceSession) {
                try await self.captureManager.captureArea(
                    rect: rect, screen: screen
                )
            }
        }
    }

    /// Capture with a countdown delay. Useful for capturing menus and tooltips.
    func captureDelayed(seconds: Int, mode: CaptureMode) {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        let delay = max(1, min(seconds, 10))
        appState.isCountingDown = true
        appState.countdownRemaining = delay
        appState.statusMessage = "Capturing in \(delay)s..."

        CountdownOverlay.shared.show(seconds: delay) { [weak self] in
            self?.cancelDelayedCapture()
        }

        replaceDelayedCaptureTask(Task { [weak self] in
            guard let self = self else { return }
            for remaining in stride(from: delay, through: 1, by: -1) {
                if Task.isCancelled { return }
                self.appState.statusMessage = "Capturing in \(remaining)s..."
                self.appState.countdownRemaining = remaining
                CountdownOverlay.shared.updateCount(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            if Task.isCancelled { return }

            self.appState.isCountingDown = false
            self.appState.countdownRemaining = 0
            CountdownOverlay.shared.dismiss()

            // Final cancellation check to close the race window between
            // the last Task.isCancelled check and capture dispatch (M7).
            guard !Task.isCancelled else { return }

            switch mode {
            case .area:
                self.appState.isCapturing = false
                self.captureArea()
            case .fullscreen:
                await self.performFullscreenCapture(dismissDelay: true)
            case .window:
                self.appState.isCapturing = false
                self.captureWindow()
            case .scroll:
                self.appState.isCapturing = false
                self.captureScroll()
            }
        })
    }

    /// Cancel an in-progress delayed capture countdown.
    func cancelDelayedCapture() {
        delayedCaptureTask?.cancel()
        replaceDelayedCaptureTask(nil)
        appState.isCountingDown = false
        appState.countdownRemaining = 0
        appState.isCapturing = false
        appState.statusMessage = "Countdown cancelled"
        CountdownOverlay.shared.dismiss()
    }
}
