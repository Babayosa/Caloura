import AppKit
import Foundation
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")
private let entryLogger = Logger(subsystem: "com.caloura.app", category: "CaptureEntry")
private let performanceLogger = Logger(subsystem: "com.caloura.app", category: "CapturePerformance")

@MainActor
final class CapturePipeline: ObservableObject {
    static let shared = CapturePipeline()

    private let captureManager = ScreenCaptureManager.shared
    private let settings = AppSettings.shared
    private let appState = AppState.shared
    private let presetManager = PresetManager.shared
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var screenOverlays: [ScreenSelectionOverlayWindow] = []
    private var delayedCaptureTask: Task<Void, Never>?
    private var performanceMetrics = PerformanceMetricsAggregator(maxSamplesPerStage: 200, reportInterval: 20)

    private init() {}

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }

    // MARK: - Capture Entry Points

    func captureArea() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        Task {
            let entryStart = CFAbsoluteTimeGetCurrent()
            entryLogger.debug("Capture entry: request received")
            let freezeStart = CFAbsoluteTimeGetCurrent()
            // Freeze capture: take screenshots of all screens first
            // This preserves menus/tooltips that would close when overlay appears
            let frozenImages = await captureAllScreens()
            let freezeDuration = self.elapsedMilliseconds(since: freezeStart)
            logger.debug("Freeze pre-capture completed in \(freezeDuration, privacy: .public) ms (\(frozenImages.count) screen snapshots)")
            self.recordMetric(stage: .freezeSnapshot, milliseconds: freezeDuration)

            var firstMouseDownLogged = false

            overlayWindows = CaptureOverlayWindow.showOnAllScreens(
                frozenImages: frozenImages,
                onRegionSelected: { [weak self] rect, screen in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.overlayWindows = []
                        // Store for repeat capture
                        self.appState.lastCaptureRect = rect
                        self.appState.lastCaptureScreen = screen
                        // Use the frozen image instead of capturing again
                        if let frozenImage = frozenImages[screen] {
                            await self.performFrozenAreaCapture(rect: rect, screen: screen, frozenImage: frozenImage)
                        } else {
                            await self.performAreaCapture(rect: rect, screen: screen)
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
                    let firstMouseDownDuration = self.elapsedMilliseconds(since: entryStart)
                    entryLogger.info("Capture entry: first mouseDown at \(firstMouseDownDuration, privacy: .public) ms")
                    self.recordMetric(stage: .firstMouseDown, milliseconds: firstMouseDownDuration)
                }
            )

            let overlayVisibleDuration = self.elapsedMilliseconds(since: entryStart)
            entryLogger.info("Capture entry: overlay visible at \(overlayVisibleDuration, privacy: .public) ms")
            self.recordMetric(stage: .overlayVisible, milliseconds: overlayVisibleDuration)
        }
    }

    /// Capture screens for freeze mode. For multi-monitor, we freeze only the
    /// active screen to reduce latency; other screens fall back to live capture.
    private func captureAllScreens() async -> [NSScreen: CGImage] {
        let screens = NSScreen.screens

        // Single screen: no need for TaskGroup overhead
        if screens.count == 1, let screen = screens.first {
            if let image = try? await captureManager.captureFullScreen(screen: screen) {
                return [screen: image]
            }
            return [:]
        }

        // Multi-monitor: capture only the active screen to minimize delay.
        guard let activeScreen = screenForMouseLocation(in: screens) ?? NSScreen.main ?? screens.first else {
            return [:]
        }
        if let image = try? await captureManager.captureFullScreen(screen: activeScreen) {
            return [activeScreen: image]
        }
        return [:]
    }

    private func screenForMouseLocation(in screens: [NSScreen]) -> NSScreen? {
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
                        await self.performFullscreenCapture(screen: selectedScreen)
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
            // Use the system picker for window selection
            guard let filter = await WindowPickerManager.shared.pickWindow() else {
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
                try await self.captureManager.captureArea(rect: rect, screen: screen)
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

    // MARK: - Perform Captures

    private func performAreaCapture(rect: CGRect, screen: NSScreen) async {
        await performCapture(mode: .area) {
            try await self.captureManager.captureArea(rect: rect, screen: screen)
        }
    }

    /// Crop from an already-captured frozen image (for freeze capture mode)
    private func performFrozenAreaCapture(rect: CGRect, screen: NSScreen, frozenImage: CGImage) async {
        await performCapture(mode: .area) {
            // Convert screen coordinates to image coordinates
            let scale = screen.backingScaleFactor
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - rect.origin.y - rect.height

            // Calculate crop rect relative to this screen's image (pixel coordinates)
            let imageRect = CGRect(
                x: rect.origin.x * scale,
                y: flippedY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral

            // Crop the frozen image
            guard let croppedImage = frozenImage.cropping(to: imageRect) else {
                throw CaptureError.captureFailed("Failed to crop frozen image")
            }
            return croppedImage
        }
    }

    private func performFullscreenCapture(screen: NSScreen? = nil) async {
        // Brief delay to let menu bar close / overlays dismiss
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await performCapture(mode: .fullscreen) {
            try await self.captureManager.captureFullScreen(screen: screen)
        }
    }

    private func performWindowCapture(filter: SCContentFilter) async {
        await performCapture(mode: .window) {
            try await self.captureManager.captureWindow(filter: filter)
        }
    }

    // MARK: - Pipeline

    private func performCapture(mode: CaptureMode, capture: () async throws -> CGImage) async {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        logger.info("Starting capture: mode=\(mode.rawValue)")
        do {
            // Detect context before capture
            let (appName, windowTitle, category) = ContextDetector.detectContext()

            // Capture
            let captureStart = CFAbsoluteTimeGetCurrent()
            let cgImage = try await capture()
            let captureDuration = elapsedMilliseconds(since: captureStart)
            logger.info("Capture succeeded: \(cgImage.width)x\(cgImage.height)")
            logger.debug("Capture stage completed in \(captureDuration, privacy: .public) ms")
            recordMetric(stage: .capture, milliseconds: captureDuration)

            // Build context
            let context = CaptureContext(
                mode: mode,
                sourceAppName: appName,
                sourceWindowTitle: windowTitle
            )

            // Determine preset
            let preset: CapturePreset
            if settings.autoContextDetection {
                preset = presetManager.presetForCategory(category)
                    ?? presetManager.preset(named: settings.activePreset)
                    ?? CapturePreset(name: "Quick Capture")
            } else {
                preset = presetManager.preset(named: settings.activePreset)
                    ?? CapturePreset(name: "Quick Capture")
            }

            // Process (smart crop)
            let shouldCrop = settings.smartCropEnabled && preset.smartCropEnabled
            let processStart = CFAbsoluteTimeGetCurrent()
            let processed = await ImageProcessor.process(
                cgImage: cgImage,
                context: context,
                smartCropEnabled: shouldCrop
            )
            logger.debug("Image processing completed in \(self.elapsedMilliseconds(since: processStart), privacy: .public) ms")
            recordMetric(stage: .process, milliseconds: elapsedMilliseconds(since: processStart))
            processed.presetName = preset.name

            // Save to disk (async, runs on background thread)
            if settings.autoSaveToDisk {
                let saveStart = CFAbsoluteTimeGetCurrent()
                let fileURL = try await FileOrganizer.save(
                    processed,
                    baseDirectory: settings.saveDirectory,
                    subfolder: preset.subfolder,
                    imageFormat: settings.imageFormat
                )
                logger.debug("Disk save completed in \(self.elapsedMilliseconds(since: saveStart), privacy: .public) ms")
                recordMetric(stage: .save, milliseconds: elapsedMilliseconds(since: saveStart))
                processed.filePath = fileURL
                processed.fileName = fileURL.lastPathComponent
            }

            // Copy to clipboard
            if settings.autoCopyToClipboard {
                let clipboardStart = CFAbsoluteTimeGetCurrent()
                switch preset.copyMode {
                case .image:
                    await ClipboardManager.copyImage(processed)
                case .markdown:
                    ClipboardManager.copyAsMarkdown(processed)
                case .citation:
                    ClipboardManager.copyWithCitation(processed)
                case .multiFormat:
                    await ClipboardManager.copyMultiFormat(processed)
                }
                logger.debug("Clipboard stage completed in \(self.elapsedMilliseconds(since: clipboardStart), privacy: .public) ms")
                recordMetric(stage: .clipboard, milliseconds: elapsedMilliseconds(since: clipboardStart))
            }

            // Play sound
            if settings.playCaptureSound {
                NSSound(named: "Tink")?.play()
            }

            // Update state
            appState.lastScreenshot = processed
            appState.statusMessage = "Captured!"

            // Only add to history and run OCR if saving to disk (otherwise no file to reference)
            if settings.autoSaveToDisk {
                let newItem = processed.toScreenshotItem()
                let screenshotID = newItem.id  // Capture ID before adding to avoid race condition
                appState.addScreenshot(newItem)

                // Background OCR — use the captured UUID to update the correct entry
                // even if another capture completes before OCR finishes.
                let cgImageForOCR = processed.cgImage
                Task.detached {
                    if let text = try? await OCREngine.recognizeText(in: cgImageForOCR),
                       !text.isEmpty {
                        await MainActor.run {
                            let state = AppState.shared
                            guard let index = state.recentScreenshots.firstIndex(where: { $0.id == screenshotID }) else { return }
                            let item = state.recentScreenshots[index]
                            let updated = ScreenshotItem(
                                id: item.id,
                                timestamp: item.timestamp,
                                filePath: item.filePath,
                                fileName: item.fileName,
                                sourceAppName: item.sourceAppName,
                                sourceWindowTitle: item.sourceWindowTitle,
                                captureMode: item.captureMode,
                                presetName: item.presetName,
                                ocrText: text,
                                width: item.width,
                                height: item.height,
                            title: item.title,
                            tags: item.tags
                        )
                        state.recentScreenshots[index] = updated
                        state.saveHistory()
                    }
                }
                }
            }

            // Show Quick Access Overlay
            QuickAccessOverlay.shared.show(for: processed)

            // Notify URL scheme handler and other listeners
            NotificationCenter.default.post(name: .captureCompleted, object: nil)
            let totalDuration = self.elapsedMilliseconds(since: pipelineStart)
            logger.info("Capture pipeline finished in \(totalDuration, privacy: .public) ms")
            recordMetric(stage: .total, milliseconds: totalDuration)

        } catch CaptureError.noPermission {
            logger.warning("Capture failed: no permission")
            PermissionCoordinator.shared.handleCapturePermissionFailure()
        } catch {
            logger.error("Capture failed: \(error.localizedDescription)")
            appState.statusMessage = "Capture failed: \(error.localizedDescription)"
        }

        appState.isCapturing = false
    }

    private func recordMetric(stage: PerformanceMetricStage, milliseconds: Double) {
        performanceLogger.debug("metric_sample stage=\(stage.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
        if let summary = performanceMetrics.record(stage: stage, milliseconds: milliseconds) {
            let stageName = summary.stage.rawValue
            let sampleCount = summary.sampleCount
            let latest = summary.latestMilliseconds
            let p50 = summary.p50Milliseconds
            let p95 = summary.p95Milliseconds
            performanceLogger.info("metric_summary stage=\(stageName, privacy: .public) samples=\(sampleCount, privacy: .public) latest_ms=\(latest, privacy: .public) p50_ms=\(p50, privacy: .public) p95_ms=\(p95, privacy: .public)")
        }
    }

    // MARK: - Distribution Actions

    func copyLastAsMarkdown() {
        guard let screenshot = appState.lastScreenshot else { return }
        ClipboardManager.copyAsMarkdown(screenshot)
        appState.statusMessage = "Copied as Markdown"
    }

    func copyLastWithCitation() {
        guard let screenshot = appState.lastScreenshot else { return }
        ClipboardManager.copyWithCitation(screenshot)
        appState.statusMessage = "Copied with citation"
    }

    func copyLastOCRText() {
        guard let lastItem = appState.recentScreenshots.first,
              let text = lastItem.ocrText, !text.isEmpty else {
            appState.statusMessage = "No OCR text available"
            return
        }
        ClipboardManager.copyOCRText(text)
        appState.statusMessage = "Copied OCR text"
    }
}
