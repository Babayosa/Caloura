// swiftlint:disable file_length
import AppKit
import CryptoKit
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")
private let performanceLogger = Logger(subsystem: "com.caloura.app", category: "CapturePerformance")

@MainActor
// swiftlint:disable:next type_body_length
final class CapturePipeline: ObservableObject {
    static let shared = CapturePipeline()

    // MARK: - Closure Type Aliases

    typealias DetectContextFn = () -> DetectedContext
    typealias ProcessImageFn = (CGImage, CaptureContext, Bool) async -> ProcessedScreenshot
    typealias SaveFileFn = (ProcessedScreenshot, String, String?, String) async throws -> URL
    typealias PersistArtifactFn = (ProcessedScreenshot, CapturePreset) async throws -> Void
    typealias CopyToClipboardFn = (ProcessedScreenshot, CopyMode) async throws -> Void
    typealias RecognizeTextFn = (CGImage) async throws -> String
    typealias HandlePermissionFailureFn = @MainActor () async -> Void
    typealias ShowQuickAccessFn = (ProcessedScreenshot) -> Void
    typealias PlaySoundFn = () -> Void
    typealias PostNotificationFn = (Notification.Name) -> Void
    typealias PresetForCategoryFn = (AppCategory) -> CapturePreset?
    typealias PresetByNameFn = (String) -> CapturePreset?

    // MARK: - Dependencies

    let captureManager = ScreenCaptureManager.shared
    let capturePerformanceRecorder = CapturePerformanceRecorder.shared
    let settings: AppSettings
    let appState: AppState
    private let detectContext: DetectContextFn
    private let processImage: ProcessImageFn
    private let saveFile: SaveFileFn
    private let persistArtifact: PersistArtifactFn
    private let copyToClipboard: CopyToClipboardFn
    private let recognizeText: RecognizeTextFn
    private let handlePermissionFailure: HandlePermissionFailureFn
    private let showQuickAccess: ShowQuickAccessFn
    private let playSoundAction: PlaySoundFn
    private let postNotification: PostNotificationFn
    private let presetForCategory: PresetForCategoryFn
    private let presetByName: PresetByNameFn

    // MARK: - Mutable State

    var overlayWindows: [CaptureOverlayWindow] = []
    var screenOverlays: [ScreenSelectionOverlayWindow] = []
    var areaCaptureSession: AreaCaptureSessionCoordinator?
    var fullscreenCaptureSession: FullscreenCaptureSessionCoordinator?
    var delayedCaptureTask: Task<Void, Never>?
    var scrollCaptureTask: Task<ScrollCaptureEngine.Result, Never>?
    private var ocrTask: Task<Void, Never>?
    /// Tracks whether the first mouseDown metric has been logged for the current capture session.
    var firstMouseDownLogged = false
    /// Monotonic counter to detect stale overlay callbacks from a previous capture session.
    var captureSessionID: UInt = 0
    private var performanceMetrics = PerformanceMetricsAggregator(
        maxSamplesPerStage: 200,
        reportInterval: 20
    )

    // MARK: - Init (Production)

    private init() {
        self.settings = AppSettings.shared
        self.appState = AppState.shared
        let presetMgr = PresetManager.shared
        self.detectContext = { ContextDetector.detectContext() }
        self.processImage = { cgImage, context, smartCrop in
            await ImageProcessor.process(
                cgImage: cgImage, context: context, smartCropEnabled: smartCrop
            )
        }
        self.saveFile = { processed, baseDir, subfolder, format in
            try await FileOrganizer.save(
                processed, baseDirectory: baseDir,
                subfolder: subfolder, imageFormat: format
            )
        }
        self.persistArtifact = { processed, preset in
            _ = try await ScreenshotArtifactCoordinator.shared.saveCapture(
                processed,
                subfolder: preset.subfolder
            )
        }
        self.copyToClipboard = { processed, copyMode in
            switch copyMode {
            case .image:
                try await ClipboardManager.copyImage(processed)
            case .markdown:
                try ClipboardManager.copyAsMarkdown(processed)
            case .citation:
                try ClipboardManager.copyWithCitation(processed)
            case .multiFormat:
                try await ClipboardManager.copyMultiFormat(processed)
            }
        }
        self.recognizeText = { cgImage in
            try await OCREngine.recognizeText(in: cgImage)
        }
        self.handlePermissionFailure = {
            await PermissionCoordinator.shared.handleCapturePermissionFailure()
        }
        self.showQuickAccess = { processed in
            QuickAccessOverlay.shared.show(for: processed)
        }
        self.playSoundAction = {
            NSSound(named: "Tink")?.play()
        }
        self.postNotification = { name in
            NotificationCenter.default.post(name: name, object: nil)
        }
        self.presetForCategory = { category in
            presetMgr.presetForCategory(category)
        }
        self.presetByName = { name in
            presetMgr.preset(named: name)
        }
    }

    // MARK: - Init (Testing)

    init(
        settings: AppSettings,
        appState: AppState,
        detectContext: @escaping DetectContextFn,
        processImage: @escaping ProcessImageFn,
        saveFile: @escaping SaveFileFn,
        persistArtifact: @escaping PersistArtifactFn,
        copyToClipboard: @escaping CopyToClipboardFn,
        recognizeText: @escaping RecognizeTextFn,
        handlePermissionFailure: @escaping HandlePermissionFailureFn,
        showQuickAccess: @escaping ShowQuickAccessFn,
        playSoundAction: @escaping PlaySoundFn,
        postNotification: @escaping PostNotificationFn,
        presetForCategory: @escaping PresetForCategoryFn,
        presetByName: @escaping PresetByNameFn
    ) {
        self.settings = settings
        self.appState = appState
        self.detectContext = detectContext
        self.processImage = processImage
        self.saveFile = saveFile
        self.persistArtifact = persistArtifact
        self.copyToClipboard = copyToClipboard
        self.recognizeText = recognizeText
        self.handlePermissionFailure = handlePermissionFailure
        self.showQuickAccess = showQuickAccess
        self.playSoundAction = playSoundAction
        self.postNotification = postNotification
        self.presetForCategory = presetForCategory
        self.presetByName = presetByName
    }

    func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }

    // MARK: - Pipeline

    func performCapture(
        mode: CaptureMode,
        performanceSession: CapturePerformanceRecorder.Session? = nil,
        capture: () async throws -> CGImage
    ) async {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        logger.info("Starting capture: mode=\(mode.rawValue)")
        do {
            let detectedContext = detectContext()
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
            if let performanceSession {
                capturePerformanceRecorder.recordDuration(
                    .screenshotDuration,
                    milliseconds: captureDuration,
                    in: performanceSession
                )
            }

            let (processed, preset) = await processCapture(
                cgImage: cgImage, mode: mode,
                appName: appName, windowTitle: windowTitle, category: category
            )
            let hasDeferredEnrichment = settings.autoSaveToDisk
            appState.setCapturePreviewPhase(
                hasDeferredEnrichment ? .enrichmentPending : .rawPreviewReady,
                for: processed.id
            )

            await distributeCapture(
                processed,
                preset: preset,
                performanceSession: performanceSession
            )
            showQuickAccess(processed)
            if let performanceSession {
                capturePerformanceRecorder.mark(.rawPreviewVisible, in: performanceSession)
            }
            postNotification(.captureCompleted)

            let totalDuration = self.elapsedMilliseconds(since: pipelineStart)
            logger.info(
                "Capture pipeline finished in \(totalDuration, privacy: .public) ms"
            )
            recordMetric(stage: .total, milliseconds: totalDuration)

            if settings.autoSaveToDisk {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    await self.saveToDisk(
                        processed,
                        preset: preset,
                        performanceSession: performanceSession
                    )
                    self.addToHistoryWithOCR(processed)
                    if let performanceSession {
                        self.capturePerformanceRecorder.finishSession(performanceSession)
                    }
                }
            } else {
                appState.setCapturePreviewPhase(.enrichmentComplete, for: processed.id)
                if let performanceSession {
                    capturePerformanceRecorder.finishSession(performanceSession)
                }
            }
            appState.isCapturing = false

        } catch CaptureError.noPermission {
            logger.warning("Capture failed: no permission")
            await handlePermissionFailure()
            if let performanceSession {
                capturePerformanceRecorder.finishSession(performanceSession)
            }
        } catch {
            logger.error("Capture failed: \(error.localizedDescription)")
            appState.statusMessage = "Capture failed: \(error.localizedDescription)"
            if let performanceSession {
                capturePerformanceRecorder.finishSession(performanceSession)
            }
        }

        if appState.isCapturing {
            appState.isCapturing = false
        }
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
            preset = presetForCategory(category)
                ?? presetByName(settings.activePreset)
                ?? CapturePreset(name: "Quick Capture")
        } else {
            preset = presetByName(settings.activePreset)
                ?? CapturePreset(name: "Quick Capture")
        }

        let shouldCrop = settings.smartCropEnabled && preset.smartCropEnabled
        let processStart = CFAbsoluteTimeGetCurrent()
        let processed = await processImage(cgImage, context, shouldCrop)
        let processDuration = elapsedMilliseconds(since: processStart)
        logger.debug(
            "Image processing completed in \(processDuration, privacy: .public) ms"
        )
        recordMetric(stage: .process, milliseconds: processDuration)
        processed.presetName = preset.name

        return (processed, preset)
    }

    // MARK: - Save to Disk

    private func saveToDisk(
        _ processed: ProcessedScreenshot,
        preset: CapturePreset,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        let saveStart = CFAbsoluteTimeGetCurrent()
        do {
            try await persistArtifact(processed, preset)
            let saveDuration = elapsedMilliseconds(since: saveStart)
            logger.debug(
                "Disk save completed in \(saveDuration, privacy: .public) ms"
            )
            recordMetric(stage: .save, milliseconds: saveDuration)
            if let performanceSession {
                capturePerformanceRecorder.recordDuration(
                    .saveComplete,
                    milliseconds: saveDuration,
                    in: performanceSession
                )
            }
        } catch {
            let desc = error.localizedDescription
            logger.error("File save failed: \(desc, privacy: .public)")
            appState.statusMessage = "Save failed: \(desc)"
        }
    }

    // MARK: - Distribute Capture

    private func distributeCapture(
        _ processed: ProcessedScreenshot,
        preset: CapturePreset,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        if settings.autoCopyToClipboard {
            let clipboardStart = CFAbsoluteTimeGetCurrent()
            do {
                try await copyToClipboard(processed, preset.copyMode)
                let clipDuration = elapsedMilliseconds(since: clipboardStart)
                logger.debug(
                    "Clipboard stage completed in \(clipDuration, privacy: .public) ms"
                )
                recordMetric(stage: .clipboard, milliseconds: clipDuration)
                if let performanceSession {
                    capturePerformanceRecorder.recordDuration(
                        .clipboardComplete,
                        milliseconds: clipDuration,
                        in: performanceSession
                    )
                }
            } catch {
                let desc = error.localizedDescription
                logger.error("Clipboard copy failed: \(desc, privacy: .public)")
                appState.statusMessage = "Clipboard failed: \(desc)"
            }
        }

        if settings.playCaptureSound {
            playSoundAction()
        }

        appState.lastScreenshot = processed
        appState.statusMessage = "Captured!"
    }

    // MARK: - History + OCR

    func addToHistoryWithOCR(_ processed: ProcessedScreenshot) {
        let screenshotID = processed.id
        appState.syncProcessedScreenshot(processed)

        // Cancel any in-flight OCR task to avoid unbounded pile-up (H9).
        // Only the latest capture's OCR matters for history.
        ocrTask?.cancel()

        let cgImageForOCR = processed.cgImage
        let recognizeTextFn = self.recognizeText
        let capturedAppState = self.appState
        ocrTask = Task.detached {
            defer {
                Task { @MainActor in
                    capturedAppState.setCapturePreviewPhase(
                        .enrichmentComplete,
                        for: screenshotID
                    )
                }
            }
            do {
                guard !Task.isCancelled else { return }
                let text = try await recognizeTextFn(cgImageForOCR)
                guard !Task.isCancelled else { return }
                guard !text.isEmpty else { return }
                await MainActor.run {
                    capturedAppState.updateScreenshot(id: screenshotID) { item in
                        item.ocrText = text
                    }
                }

                // AI post-processing
                await detectPIIIfEnabled(
                    cgImage: cgImageForOCR,
                    screenshotID: screenshotID,
                    appState: capturedAppState
                )
                await generateEmbeddingIfEnabled(
                    text: text,
                    screenshotID: screenshotID,
                    appState: capturedAppState
                )
                await generateSmartMetadataIfEnabled(
                    text: text,
                    screenshotID: screenshotID,
                    appState: capturedAppState
                )
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

// MARK: - AI Post-Processing Helpers

private func detectPIIIfEnabled(
    cgImage: CGImage,
    screenshotID: UUID,
    appState: AppState
) async {
    let enabled = await MainActor.run { AppSettings.shared.autoDetectPII }
    guard enabled else { return }
    do {
        let detections = try await PIIDetector.detect(in: cgImage)
        guard !detections.isEmpty else { return }
        await MainActor.run {
            appState.lastPIIResult = PIIDetectionResult(
                detections: detections,
                screenshotID: screenshotID
            )
        }
    } catch {
        // PII detection failure is non-fatal
    }
}

private func generateEmbeddingIfEnabled(
    text: String,
    screenshotID: UUID,
    appState: AppState
) async {
    let enabled = await MainActor.run {
        AppSettings.shared.semanticSearchEnabled
    }
    guard enabled, !text.isEmpty else { return }
    guard let vector = EmbeddingEngine.embed(text) else { return }
    let textHash = stableHash(text)
    let store = await MainActor.run { appState.embeddingStore }
    store.add(
        screenshotID: screenshotID,
        vector: vector,
        textHash: textHash
    )
    store.save()
    await MainActor.run {
        appState.updateScreenshot(id: screenshotID) { item in
            item.embeddingVersion = EmbeddingEngine.modelVersion
        }
    }
}

private func generateSmartMetadataIfEnabled(
    text: String,
    screenshotID: UUID,
    appState: AppState
) async {
    let enabled = await MainActor.run {
        AppSettings.shared.smartMetadataEnabled
    }
    guard enabled, !text.isEmpty else { return }
    let (sourceApp, windowTitle) = await MainActor.run {
        let item = appState.recentScreenshots.first { $0.id == screenshotID }
        return (item?.sourceAppName, item?.sourceWindowTitle)
    }
    guard let metadata = await SmartMetadataGenerator.shared.generate(
        ocrText: text, sourceApp: sourceApp, windowTitle: windowTitle
    ) else { return }
    await MainActor.run {
        guard let idx = appState.recentScreenshots.firstIndex(
            where: { $0.id == screenshotID }
        ) else { return }
        appState.recentScreenshots[idx].smartFileName = metadata.smartFileName
        appState.recentScreenshots[idx].summary = metadata.summary
        appState.recentScreenshots[idx].autoTags = metadata.tags
        appState.saveHistory()
    }
}

private func stableHash(_ text: String) -> String {
    let data = Data(text.utf8)
    return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
}
