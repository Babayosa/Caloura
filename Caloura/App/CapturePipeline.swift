import AppKit
import Foundation

@MainActor
final class CapturePipeline: ObservableObject {
    static let shared = CapturePipeline()

    private let captureManager = ScreenCaptureManager.shared
    private let settings = AppSettings.shared
    private let appState = AppState.shared
    private let presetManager = PresetManager.shared
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var windowOverlays: [WindowSelectionOverlayWindow] = []

    private init() {}

    // MARK: - Capture Entry Points

    func captureArea() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        Task {
            overlayWindows = CaptureOverlayWindow.showOnAllScreens(
                onRegionSelected: { [weak self] rect, screen in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.overlayWindows = []
                        // Store for repeat capture
                        self.appState.lastCaptureRect = rect
                        self.appState.lastCaptureScreen = screen
                        await self.performAreaCapture(rect: rect, screen: screen)
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

    func captureFullscreen() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        Task {
            await performFullscreenCapture()
        }
    }

    func captureWindow() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true

        Task {
            do {
                let windows = try await captureManager.getWindows()
                if windows.isEmpty {
                    appState.isCapturing = false
                    appState.statusMessage = "No windows available to capture."
                    return
                }

                windowOverlays = WindowSelectionOverlayWindow.showOnAllScreens(
                    windows: windows,
                    onWindowSelected: { [weak self] window in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.windowOverlays = []
                            await self.performWindowCapture(window: window)
                        }
                    },
                    onCancelled: { [weak self] in
                        Task { @MainActor in
                            self?.windowOverlays = []
                            self?.appState.isCapturing = false
                        }
                    }
                )
            } catch CaptureError.noPermission {
                appState.isCapturing = false
                captureManager.showPermissionAlert()
            } catch {
                appState.isCapturing = false
                appState.statusMessage = "Failed to enumerate windows: \(error.localizedDescription)"
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
        appState.statusMessage = "Capturing in \(delay)s..."

        Task {
            for remaining in stride(from: delay, through: 1, by: -1) {
                appState.statusMessage = "Capturing in \(remaining)s..."
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }

            switch mode {
            case .area:
                appState.isCapturing = false
                captureArea()
            case .fullscreen:
                await performFullscreenCapture()
            case .window:
                appState.isCapturing = false
                captureWindow()
            }
        }
    }

    // MARK: - Perform Captures

    private func performAreaCapture(rect: CGRect, screen: NSScreen) async {
        await performCapture(mode: .area) {
            try await self.captureManager.captureArea(rect: rect, screen: screen)
        }
    }

    private func performFullscreenCapture() async {
        // Brief delay to let menu bar close
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await performCapture(mode: .fullscreen) {
            try await self.captureManager.captureFullScreen()
        }
    }

    private func performWindowCapture(window: CaptureWindow) async {
        await performCapture(mode: .window) {
            try await self.captureManager.captureWindow(window)
        }
    }

    // MARK: - Pipeline

    private func performCapture(mode: CaptureMode, capture: () async throws -> CGImage) async {
        do {
            // Detect context before capture
            let (appName, windowTitle, category) = ContextDetector.detectContext()

            // Capture
            let cgImage = try await capture()

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

            // Save to disk
            if settings.autoSaveToDisk {
                let fileURL = try FileOrganizer.save(
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
            appState.addScreenshot(processed.toScreenshotItem())
            appState.statusMessage = "Captured!"

            // Show Quick Access Overlay
            QuickAccessOverlay.shared.show(for: processed)

            // Notify URL scheme handler and other listeners
            NotificationCenter.default.post(name: .captureCompleted, object: nil)

            // Background OCR — capture the item's UUID so we update the correct entry
            // even if another capture completes before OCR finishes.
            let cgImageForOCR = processed.cgImage
            let screenshotID = appState.recentScreenshots.first?.id
            Task.detached {
                if let text = try? await OCREngine.recognizeText(in: cgImageForOCR),
                   !text.isEmpty,
                   let targetID = screenshotID {
                    await MainActor.run {
                        let state = AppState.shared
                        guard let index = state.recentScreenshots.firstIndex(where: { $0.id == targetID }) else { return }
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

        } catch CaptureError.noPermission {
            captureManager.showPermissionAlert()
        } catch {
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
