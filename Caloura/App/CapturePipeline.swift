import AppKit
import Foundation
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")
private let performanceLogger = Logger(subsystem: "com.caloura.app", category: "CapturePerformance")

@MainActor
final class CapturePipeline: ObservableObject {
    static let shared = CapturePipeline()

    let captureManager = ScreenCaptureManager.shared
    let settings = AppSettings.shared
    let appState = AppState.shared
    let presetManager = PresetManager.shared
    var overlayWindows: [CaptureOverlayWindow] = []
    var screenOverlays: [ScreenSelectionOverlayWindow] = []
    var delayedCaptureTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    /// Tracks whether the first mouseDown metric has been logged for the current capture session.
    var firstMouseDownLogged = false
    /// Monotonic counter to detect stale overlay callbacks from a previous capture session.
    var captureSessionID: UInt = 0
    private var performanceMetrics = PerformanceMetricsAggregator(
        maxSamplesPerStage: 200,
        reportInterval: 20
    )

    private init() {}

    func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }

    // MARK: - Pipeline

    func performCapture(
        mode: CaptureMode,
        capture: () async throws -> CGImage
    ) async {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        logger.info("Starting capture: mode=\(mode.rawValue)")
        do {
            let detectedContext = ContextDetector.detectContext()
            let appName = detectedContext.appName
            let windowTitle = detectedContext.windowTitle
            let category = detectedContext.category

            let captureStart = CFAbsoluteTimeGetCurrent()
            let cgImage = try await capture()
            let captureDuration = elapsedMilliseconds(since: captureStart)
            logger.info("Capture succeeded: \(cgImage.width)x\(cgImage.height)")
            logger.debug(
                "Capture stage completed in \(captureDuration, privacy: .public) ms"
            )
            recordMetric(stage: .capture, milliseconds: captureDuration)

            let (processed, preset) = await processCapture(
                cgImage: cgImage, mode: mode,
                appName: appName, windowTitle: windowTitle, category: category
            )
            await distributeCapture(processed, preset: preset)
            if settings.autoSaveToDisk {
                addToHistoryWithOCR(processed)
            }

            QuickAccessOverlay.shared.show(for: processed)
            NotificationCenter.default.post(name: .captureCompleted, object: nil)
            let totalDuration = self.elapsedMilliseconds(since: pipelineStart)
            logger.info(
                "Capture pipeline finished in \(totalDuration, privacy: .public) ms"
            )
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

    // MARK: - Process Capture

    private func processCapture(
        cgImage: CGImage, mode: CaptureMode,
        appName: String?, windowTitle: String?, category: AppCategory
    ) async -> (ProcessedScreenshot, CapturePreset) {
        let context = CaptureContext(
            mode: mode,
            sourceAppName: appName,
            sourceWindowTitle: windowTitle
        )

        let preset: CapturePreset
        if settings.autoContextDetection {
            preset = presetManager.presetForCategory(category)
                ?? presetManager.preset(named: settings.activePreset)
                ?? CapturePreset(name: "Quick Capture")
        } else {
            preset = presetManager.preset(named: settings.activePreset)
                ?? CapturePreset(name: "Quick Capture")
        }

        let shouldCrop = settings.smartCropEnabled && preset.smartCropEnabled
        let processStart = CFAbsoluteTimeGetCurrent()
        let processed = await ImageProcessor.process(
            cgImage: cgImage,
            context: context,
            smartCropEnabled: shouldCrop
        )
        let processDuration = elapsedMilliseconds(since: processStart)
        logger.debug(
            "Image processing completed in \(processDuration, privacy: .public) ms"
        )
        recordMetric(stage: .process, milliseconds: processDuration)
        processed.presetName = preset.name

        if settings.autoSaveToDisk {
            let saveStart = CFAbsoluteTimeGetCurrent()
            do {
                let fileURL = try await FileOrganizer.save(
                    processed,
                    baseDirectory: settings.saveDirectory,
                    subfolder: preset.subfolder,
                    imageFormat: settings.imageFormat
                )
                let saveDuration = elapsedMilliseconds(since: saveStart)
                logger.debug(
                    "Disk save completed in \(saveDuration, privacy: .public) ms"
                )
                recordMetric(stage: .save, milliseconds: saveDuration)
                processed.filePath = fileURL
                processed.fileName = fileURL.lastPathComponent
            } catch {
                let desc = error.localizedDescription
                logger.error("File save failed: \(desc, privacy: .public)")
            }
        }

        return (processed, preset)
    }

    // MARK: - Distribute Capture

    private func distributeCapture(
        _ processed: ProcessedScreenshot,
        preset: CapturePreset
    ) async {
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
            let clipDuration = elapsedMilliseconds(since: clipboardStart)
            logger.debug(
                "Clipboard stage completed in \(clipDuration, privacy: .public) ms"
            )
            recordMetric(stage: .clipboard, milliseconds: clipDuration)
        }

        if settings.playCaptureSound {
            NSSound(named: "Tink")?.play()
        }

        appState.lastScreenshot = processed
        appState.statusMessage = "Captured!"
    }

    // MARK: - History + OCR

    private func addToHistoryWithOCR(_ processed: ProcessedScreenshot) {
        let newItem = processed.toScreenshotItem()
        let screenshotID = newItem.id
        appState.addScreenshot(newItem)

        // Cancel any in-flight OCR task to avoid unbounded pile-up (H9).
        // Only the latest capture's OCR matters for history.
        ocrTask?.cancel()

        let cgImageForOCR = processed.cgImage
        ocrTask = Task.detached {
            do {
                guard !Task.isCancelled else { return }
                let text = try await OCREngine.recognizeText(in: cgImageForOCR)
                guard !Task.isCancelled else { return }
                guard !text.isEmpty else { return }
                await MainActor.run {
                    let state = AppState.shared
                    guard let index = state.recentScreenshots.firstIndex(
                        where: { $0.id == screenshotID }
                    ) else { return }
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
            } catch {
                guard !Task.isCancelled else { return }
                let desc = error.localizedDescription
                logger.error("OCR failed: \(desc, privacy: .public)")
            }
        }
    }

    // MARK: - Metrics

    func recordMetric(stage: PerformanceMetricStage, milliseconds: Double) {
        let key = stage.rawValue
        performanceLogger.info(
            "metric_sample stage=\(key, privacy: .public) ms=\(milliseconds, privacy: .public)"
        )
        guard let summary = performanceMetrics.record(
            stage: stage, milliseconds: milliseconds
        ) else { return }
        let name = summary.stage.rawValue
        let count = summary.sampleCount
        let lat = summary.latestMilliseconds
        performanceLogger.info(
            "metric_summary \(name, privacy: .public) n=\(count, privacy: .public) latest=\(lat, privacy: .public)"
        )
        let p50 = summary.p50Milliseconds
        let p95 = summary.p95Milliseconds
        performanceLogger.info(
            "metric_percentiles \(name, privacy: .public) p50=\(p50, privacy: .public) p95=\(p95, privacy: .public)"
        )
    }
}
