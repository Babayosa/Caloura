// swiftlint:disable file_length
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
        filter: SCContentFilter,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await performCapture(mode: .window, performanceSession: performanceSession) {
            try await self.captureManager.captureWindow(filter: filter)
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

        let coordinator = AreaCaptureSessionCoordinator(
            session: performanceSession,
            performanceRecorder: capturePerformanceRecorder,
            cursorController: CaptureCursorController(),
            onSelection: { [weak self] rect, screen, frozenImage in
                guard let self = self else { return }
                guard self.captureSessionID == sessionID else { return }
                self.overlayWindows = []
                self.areaCaptureSession = nil
                self.appState.lastCaptureRect = rect
                self.appState.lastCaptureScreen = screen
                if let frozenImage {
                    await self.performFrozenAreaCapture(
                        rect: rect,
                        screen: screen,
                        frozenImage: frozenImage,
                        performanceSession: performanceSession
                    )
                } else {
                    await self.performAreaCapture(
                        rect: rect,
                        screen: screen,
                        performanceSession: performanceSession
                    )
                }
            },
            onCancel: { [weak self] in
                guard let self = self else { return }
                guard self.captureSessionID == sessionID else { return }
                self.overlayWindows = []
                self.areaCaptureSession = nil
                self.appState.isCapturing = false
                self.capturePerformanceRecorder.finishSession(performanceSession)
            },
            onFirstInteraction: { [weak self] in
                guard let self = self, !self.firstMouseDownLogged else { return }
                self.firstMouseDownLogged = true
                let duration = self.elapsedMilliseconds(since: entryStart)
                entryLogger.info(
                    "Capture entry: first mouseDown at \(duration, privacy: .public) ms"
                )
                self.recordMetric(
                    stage: .firstMouseDown,
                    milliseconds: duration
                )
            }
        )
        areaCaptureSession?.dismiss()
        areaCaptureSession = coordinator
        firstMouseDownLogged = false
        coordinator.present()
        overlayWindows = coordinator.overlayWindows

        let overlayVisibleDuration = self.elapsedMilliseconds(since: entryStart)
        entryLogger.info(
            "Capture entry: overlay visible at \(overlayVisibleDuration, privacy: .public) ms"
        )
        self.recordMetric(
            stage: .overlayVisible,
            milliseconds: overlayVisibleDuration
        )

        Task { [weak self, weak coordinator] in
            guard let self = self else { return }
            let frozenImages = await self.freezeScreens(entryStart: entryStart)
            await MainActor.run {
                guard self.captureSessionID == sessionID,
                      self.areaCaptureSession === coordinator else {
                    return
                }
                coordinator?.updateFrozenImages(frozenImages)
            }
        }
    }

    private func freezeScreens(
        entryStart: CFAbsoluteTime
    ) async -> [NSScreen: CGImage] {
        let freezeStart = CFAbsoluteTimeGetCurrent()
        let frozenImages = await captureAllScreens()
        let freezeDuration = self.elapsedMilliseconds(since: freezeStart)
        let screenCount = frozenImages.count
        logger.debug(
            "Freeze pre-capture in \(freezeDuration, privacy: .public) ms (\(screenCount) screens)"
        )
        self.recordMetric(
            stage: .freezeSnapshot, milliseconds: freezeDuration
        )
        return frozenImages
    }

    /// Capture screens for freeze mode. For multi-monitor, we freeze only the
    /// active screen to reduce latency; other screens fall back to live capture.
    func captureAllScreens() async -> [NSScreen: CGImage] {
        let screens = NSScreen.screens

        // Single screen: no need for TaskGroup overhead
        if screens.count == 1, let screen = screens.first {
            if let image = try? await captureManager.captureFullScreen(
                screen: screen
            ) {
                return [screen: image]
            }
            return [:]
        }

        // Multi-monitor: capture only the active screen to minimize delay.
        guard let activeScreen = screenForMouseLocation(in: screens)
                ?? NSScreen.main ?? screens.first else {
            return [:]
        }
        if let image = try? await captureManager.captureFullScreen(
            screen: activeScreen
        ) {
            return [activeScreen: image]
        }
        return [:]
    }

    func screenForMouseLocation(in screens: [NSScreen]) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
    }

    func captureFullscreen() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .fullscreen)

        if NSScreen.screens.count > 1 {
            let coordinator = FullscreenCaptureSessionCoordinator(
                session: performanceSession,
                performanceRecorder: capturePerformanceRecorder,
                cursorController: CaptureCursorController(),
                onSelection: { [weak self] selectedScreen in
                    guard let self = self else { return }
                    self.screenOverlays = []
                    self.fullscreenCaptureSession = nil
                    await self.performFullscreenCapture(
                        screen: selectedScreen,
                        dismissDelay: true,
                        performanceSession: performanceSession
                    )
                },
                onCancel: { [weak self] in
                    guard let self = self else { return }
                    self.screenOverlays = []
                    self.fullscreenCaptureSession = nil
                    self.appState.isCapturing = false
                    self.capturePerformanceRecorder.finishSession(performanceSession)
                }
            )
            fullscreenCaptureSession?.dismiss()
            fullscreenCaptureSession = coordinator
            coordinator.present()
            screenOverlays = coordinator.overlayWindows
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

        Task {
            let coordinator = WindowCaptureSessionCoordinator(
                session: performanceSession,
                performanceRecorder: capturePerformanceRecorder,
                captureManager: captureManager,
                pickWindow: { onPresented in
                    await WindowPickerManager.shared.pickWindow(
                        onPresented: onPresented
                    )
                }
            )
            guard let filter = await coordinator.pick() else {
                appState.isCapturing = false
                capturePerformanceRecorder.finishSession(performanceSession)
                return
            }
            await performWindowCapture(
                filter: filter,
                performanceSession: performanceSession
            )
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

        delayedCaptureTask = Task { [weak self] in
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
        }
    }

    // MARK: Scroll Capture

    func captureScroll() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true
        captureSessionID &+= 1

        Task {
            let entryStart = CFAbsoluteTimeGetCurrent()
            entryLogger.debug("Scroll capture entry: request received")
            let frozenImages = await freezeScreens(entryStart: entryStart)
            showScrollAreaOverlays(
                frozenImages: frozenImages, entryStart: entryStart
            )
        }
    }

    private func showScrollAreaOverlays(
        frozenImages: [NSScreen: CGImage],
        entryStart: CFAbsoluteTime
    ) {
        firstMouseDownLogged = false
        let sessionID = captureSessionID

        overlayWindows = CaptureOverlayWindow.showOnAllScreens(
            frozenImages: frozenImages,
            onRegionSelected: { [weak self] rect, screen in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.captureSessionID == sessionID else { return }
                    self.overlayWindows = []
                    self.appState.lastCaptureRect = rect
                    self.appState.lastCaptureScreen = screen
                    await self.performScrollCapture(
                        rect: rect, screen: screen
                    )
                }
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.captureSessionID == sessionID else { return }
                    self.overlayWindows = []
                    self.appState.isCapturing = false
                }
            },
            onFirstMouseDown: { [weak self] in
                guard let self = self, !self.firstMouseDownLogged else { return }
                self.firstMouseDownLogged = true
                let duration = self.elapsedMilliseconds(since: entryStart)
                entryLogger.info(
                    "Scroll capture entry: first mouseDown at \(duration, privacy: .public) ms"
                )
                self.recordMetric(
                    stage: .firstMouseDown, milliseconds: duration
                )
            }
        )
    }

    func performScrollCapture(rect: CGRect, screen: NSScreen) async {
        // Brief delay to let overlay dismiss and frontmost app restore
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard AccessibilityPermissionChecker.isGranted() else {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Scroll Capture needs Accessibility access to "
                + "simulate scrolling. Please grant access in System Settings."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                AccessibilityPermissionChecker.openSystemSettings()
            }
            appState.isCapturing = false
            return
        }

        let config = ScrollCaptureEngine.Config(
            maxHeightPx: settings.scrollMaxHeight,
            scrollToTop: settings.scrollToTop,
            allowManualFallback: true,
            preferredDirection: .auto,
            modeBias: .automaticPreferred
        )

        let sessionCoordinator = ScrollCaptureSessionCoordinator(
            rect: rect,
            screen: screen
        )

        let captureManager = self.captureManager
        let captureFrameFn: (CGRect, NSScreen) async throws -> CGImage = { rect, scr in
            try await captureManager.captureArea(rect: rect, screen: scr)
        }

        let engine = ScrollCaptureEngine()
        let task = Task {
            await engine.capture(
                region: rect,
                screen: screen,
                config: config,
                control: sessionCoordinator.control,
                captureFrame: captureFrameFn,
                onProgress: { progress in
                    sessionCoordinator.update(progress)
                }
            )
        }
        scrollCaptureTask = task
        sessionCoordinator.bind(task: task)

        let result = await task.value
        sessionCoordinator.dismiss()

        switch result {
        case .success(let output):
            if output.terminationReason == .manualFinished {
                appState.statusMessage = "Manual scroll capture finished"
            } else if output.terminationReason == .maxHeightReached {
                appState.statusMessage = "Scroll capture reached the max height"
            }
            await performCapture(mode: .scroll) { output.image }
        case .cancelled:
            appState.statusMessage = "Scroll capture cancelled"
            appState.isCapturing = false
        case .failed(CaptureError.noPermission):
            appState.isCapturing = false
            await PermissionCoordinator.shared.handleCapturePermissionFailure()
        case .failed(let error):
            let desc = error.localizedDescription
            logger.error("Scroll capture failed: \(desc, privacy: .public)")
            appState.statusMessage = "Scroll capture failed: \(desc)"
            appState.isCapturing = false
        }
    }

    /// Cancel an in-progress delayed capture countdown.
    func cancelDelayedCapture() {
        delayedCaptureTask?.cancel()
        delayedCaptureTask = nil
        appState.isCountingDown = false
        appState.countdownRemaining = 0
        appState.isCapturing = false
        appState.statusMessage = "Countdown cancelled"
        CountdownOverlay.shared.dismiss()
    }
}

@MainActor
private final class ScrollCaptureSessionCoordinator {
    let control = ScrollCaptureControl()

    private let overlay = ScrollProgressOverlay()
    private var task: Task<ScrollCaptureEngine.Result, Never>?

    init(rect: CGRect, screen: NSScreen) {
        overlay.show(
            near: rect,
            screen: screen,
            onCancel: { [weak self] in
                self?.task?.cancel()
            },
            onSwitchToManual: { [control] in
                Task {
                    await control.requestManual()
                }
            },
            onFinish: { [control] in
                Task {
                    await control.requestFinish()
                }
            }
        )
    }

    func bind(task: Task<ScrollCaptureEngine.Result, Never>) {
        self.task = task
    }

    func update(_ progress: ScrollCaptureProgress) {
        overlay.update(progress)
    }

    func dismiss() {
        overlay.dismiss()
        task = nil
    }
}
