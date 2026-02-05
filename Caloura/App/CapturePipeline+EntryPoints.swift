import AppKit
import Foundation
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")
private let entryLogger = Logger(subsystem: "com.caloura.app", category: "CaptureEntry")

// MARK: - Capture Entry Points

extension CapturePipeline {

    // MARK: Perform Captures

    func performAreaCapture(rect: CGRect, screen: NSScreen) async {
        await performCapture(mode: .area) {
            try await self.captureManager.captureArea(
                rect: rect, screen: screen
            )
        }
    }

    /// Crop from an already-captured frozen image (for freeze capture mode)
    func performFrozenAreaCapture(
        rect: CGRect,
        screen: NSScreen,
        frozenImage: CGImage
    ) async {
        await performCapture(mode: .area) {
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

    func performFullscreenCapture(screen: NSScreen? = nil) async {
        // Brief delay to let menu bar close / overlays dismiss
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await performCapture(mode: .fullscreen) {
            try await self.captureManager.captureFullScreen(screen: screen)
        }
    }

    func performWindowCapture(filter: SCContentFilter) async {
        await performCapture(mode: .window) {
            try await self.captureManager.captureWindow(filter: filter)
        }
    }

    // MARK: Entry Points

    func captureArea() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        Task {
            let entryStart = CFAbsoluteTimeGetCurrent()
            entryLogger.debug("Capture entry: request received")
            let frozenImages = await freezeScreens(entryStart: entryStart)
            showAreaOverlays(
                frozenImages: frozenImages, entryStart: entryStart
            )
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

    private func showAreaOverlays(
        frozenImages: [NSScreen: CGImage],
        entryStart: CFAbsoluteTime
    ) {
        var firstMouseDownLogged = false

        overlayWindows = CaptureOverlayWindow.showOnAllScreens(
            frozenImages: frozenImages,
            onRegionSelected: { [weak self] rect, screen in
                guard let self = self else { return }
                Task { @MainActor in
                    self.overlayWindows = []
                    self.appState.lastCaptureRect = rect
                    self.appState.lastCaptureScreen = screen
                    if let frozenImage = frozenImages[screen] {
                        await self.performFrozenAreaCapture(
                            rect: rect, screen: screen,
                            frozenImage: frozenImage
                        )
                    } else {
                        await self.performAreaCapture(
                            rect: rect, screen: screen
                        )
                    }
                }
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.overlayWindows = []
                    self.appState.isCapturing = false
                }
            },
            onFirstMouseDown: { [weak self] in
                guard let self = self, !firstMouseDownLogged else { return }
                firstMouseDownLogged = true
                let duration = self.elapsedMilliseconds(since: entryStart)
                entryLogger.info(
                    "Capture entry: first mouseDown at \(duration, privacy: .public) ms"
                )
                self.recordMetric(
                    stage: .firstMouseDown, milliseconds: duration
                )
            }
        )

        let overlayVisibleDuration = self.elapsedMilliseconds(since: entryStart)
        entryLogger.info(
            "Capture entry: overlay visible at \(overlayVisibleDuration, privacy: .public) ms"
        )
        self.recordMetric(
            stage: .overlayVisible, milliseconds: overlayVisibleDuration
        )
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

        if NSScreen.screens.count > 1 {
            screenOverlays = ScreenSelectionOverlayWindow.showOnAllScreens(
                onScreenSelected: { [weak self] selectedScreen in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.screenOverlays = []
                        await self.performFullscreenCapture(
                            screen: selectedScreen
                        )
                    }
                },
                onCancelled: { [weak self] in
                    Task { @MainActor in
                        self?.screenOverlays = []
                        self?.appState.isCapturing = false
                    }
                }
            )
        } else {
            Task {
                await performFullscreenCapture()
            }
        }
    }

    func captureWindow() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        Task {
            guard let filter = await WindowPickerManager.shared.pickWindow()
            else {
                appState.isCapturing = false
                return
            }
            await performWindowCapture(filter: filter)
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

        let screen = appState.lastCaptureScreen
        Task {
            await performCapture(mode: .area) {
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

            switch mode {
            case .area:
                self.appState.isCapturing = false
                self.captureArea()
            case .fullscreen:
                await self.performFullscreenCapture()
            case .window:
                self.appState.isCapturing = false
                self.captureWindow()
            }
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
