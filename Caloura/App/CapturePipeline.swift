import AppKit
import Foundation
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")

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

    private init() {}

    // MARK: - Capture Entry Points

    func captureArea() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        Task {
            // Freeze capture: take screenshots of all screens first
            // This preserves menus/tooltips that would close when overlay appears
            let frozenImages = await captureAllScreens()

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
                }
            )
        }
    }

    /// Capture all screens instantly for freeze mode (parallel for multi-monitor)
    private func captureAllScreens() async -> [NSScreen: CGImage] {
        let screens = NSScreen.screens

        // Single screen: no need for TaskGroup overhead
        if screens.count == 1, let screen = screens.first {
            if let image = try? await captureManager.captureFullScreen(screen: screen) {
                return [screen: image]
            }
            return [:]
        }

        // Multi-monitor: capture all screens in parallel
        return await withTaskGroup(of: (NSScreen, CGImage)?.self) { group in
            for screen in screens {
                group.addTask {
                    if let image = try? await self.captureManager.captureFullScreen(screen: screen) {
                        return (screen, image)
                    }
                    return nil
                }
            }

            var images: [NSScreen: CGImage] = [:]
            for await result in group {
                if let (screen, image) = result {
                    images[screen] = image
                }
            }
            return images
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
            let screenFrame = screen.frame

            // Calculate crop rect relative to this screen's image
            let imageRect = CGRect(
                x: (rect.origin.x - screenFrame.origin.x) * scale,
                y: (rect.origin.y - screenFrame.origin.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )

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
        logger.info("Starting capture: mode=\(mode.rawValue)")
        do {
            // Detect context before capture
            let (appName, windowTitle, category) = ContextDetector.detectContext()

            // Capture
            let cgImage = try await capture()
            logger.info("Capture succeeded: \(cgImage.width)x\(cgImage.height)")

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
            let processed = await ImageProcessor.process(
                cgImage: cgImage,
                context: context,
                smartCropEnabled: shouldCrop
            )
            processed.presetName = preset.name

            // Save to disk (async, runs on background thread)
            if settings.autoSaveToDisk {
                let fileURL = try await FileOrganizer.save(
                    processed,
                    baseDirectory: settings.saveDirectory,
                    subfolder: preset.subfolder,
                    imageFormat: settings.imageFormat
                )
                processed.filePath = fileURL
                processed.fileName = fileURL.lastPathComponent
            }

            // Copy to clipboard
            if settings.autoCopyToClipboard {
                switch preset.copyMode {
                case .image:
                    ClipboardManager.copyImage(processed)
                case .markdown:
                    ClipboardManager.copyAsMarkdown(processed)
                case .citation:
                    ClipboardManager.copyWithCitation(processed)
                case .multiFormat:
                    ClipboardManager.copyMultiFormat(processed)
                }
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

        } catch CaptureError.noPermission {
            logger.warning("Capture failed: no permission")
            captureManager.showPermissionAlert()
        } catch {
            logger.error("Capture failed: \(error.localizedDescription)")
            appState.statusMessage = "Capture failed: \(error.localizedDescription)"
        }

        appState.isCapturing = false
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
