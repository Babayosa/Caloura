import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")
private let performanceLogger = Logger(subsystem: "com.caloura.app", category: "CapturePerformance")

@MainActor
final class CapturePipeline: ObservableObject {
    static let shared = CapturePipeline()

    fileprivate struct ServiceDependencies {
        let settings: AppSettings
        let appState: AppState
        let detectContext: DetectContextFn
        let presetForCategory: PresetForCategoryFn
        let presetByName: PresetByNameFn
        let copyToClipboard: CopyToClipboardFn
        let saveCaptureAction: SaveCaptureActionFn
        let playSoundAction: PlaySoundFn
        let recognizeText: RecognizeTextFn
    }

    fileprivate struct Services {
        let requestResolver: CaptureRequestResolver
        let enrichmentService: CaptureEnrichmentService
        let distributionService: CaptureDistributionService
    }

    // MARK: - Closure Type Aliases

    typealias DetectContextFn = () -> DetectedContext
    typealias ProcessImageFn = (CGImage, CaptureContext, Bool) async -> ProcessedScreenshot
    typealias SaveFileFn = (ProcessedScreenshot, String, String?, String) async throws -> URL
    typealias PersistArtifactFn = (ProcessedScreenshot, CapturePreset) async throws -> Void
    typealias CopyToClipboardFn = (ProcessedScreenshot, CopyMode) async throws -> Void
    typealias SaveCaptureActionFn = @MainActor (ProcessedScreenshot) async throws -> URL
    typealias RecognizeTextFn = @Sendable (CGImage) async throws -> String
    typealias HandlePermissionFailureFn = @MainActor () async -> Void
    typealias ShowQuickAccessFn = (ProcessedScreenshot) -> Void
    typealias PlaySoundFn = () -> Void
    typealias PostNotificationFn = (Notification.Name) -> Void
    typealias PresetForCategoryFn = (AppCategory) -> CapturePreset?
    typealias PresetByNameFn = (String) -> CapturePreset?
    typealias SelectWindowCaptureFn = @MainActor (
        @escaping @MainActor () -> Void
    ) async -> WindowCaptureSessionCoordinator.SelectionResult
    typealias MakeAreaCaptureSessionFn = @MainActor (
        CapturePerformanceRecorder.Session,
        @escaping AreaCaptureSessionCoordinator.SelectionHandler,
        @escaping AreaCaptureSessionCoordinator.CancelHandler,
        AreaCaptureSessionCoordinator.EventHandler?
    ) -> any AreaCaptureSessionHandling
    typealias MakeFullscreenCaptureSessionFn = @MainActor (
        CapturePerformanceRecorder.Session,
        @escaping FullscreenCaptureSessionCoordinator.SelectionHandler,
        @escaping FullscreenCaptureSessionCoordinator.CancelHandler
    ) -> any FullscreenCaptureSessionHandling
    typealias MakeWindowCaptureSessionFn = @MainActor (
        CapturePerformanceRecorder.Session,
        @escaping @MainActor () async -> Void,
        @escaping SelectWindowCaptureFn
    ) -> any WindowCaptureSessionHandling

    // MARK: - Dependencies

    let captureManager: ScreenCaptureManaging
    let capturePerformanceRecorder: CapturePerformanceRecorder
    let settings: AppSettings
    let appState: AppState
    private let processImage: ProcessImageFn
    private let persistArtifact: PersistArtifactFn
    let handlePermissionFailure: HandlePermissionFailureFn
    private let showQuickAccess: ShowQuickAccessFn
    private let postNotification: PostNotificationFn
    let selectWindowCapture: SelectWindowCaptureFn
    let makeAreaCaptureSession: MakeAreaCaptureSessionFn
    let makeFullscreenCaptureSession: MakeFullscreenCaptureSessionFn
    let makeWindowCaptureSession: MakeWindowCaptureSessionFn
    let screenCountProvider: () -> Int
    let freezeScreensEnabled: Bool
    private let enrichmentCoordinator: CaptureEnrichmentCoordinator

    // MARK: - Mutable State

    private(set) var overlayWindows: [CaptureOverlayWindow] = []
    private(set) var screenOverlays: [ScreenSelectionOverlayWindow] = []
    private(set) var areaCaptureSession: (any AreaCaptureSessionHandling)?
    private(set) var fullscreenCaptureSession: (any FullscreenCaptureSessionHandling)?
    private(set) var delayedCaptureTask: Task<Void, Never>?
    var scrollCaptureTask: Task<ScrollCaptureEngine.Result, Never>?
    /// Tracks whether the first mouseDown metric has been logged for the current capture session.
    var firstMouseDownLogged = false
    /// Monotonic counter to detect stale overlay callbacks from a previous capture session.
    var captureSessionID: UInt = 0
    private var performanceMetrics = PerformanceMetricsAggregator(
        maxSamplesPerStage: 200,
        reportInterval: 20
    )
    private let requestResolver: CaptureRequestResolver
    let distributionService: CaptureDistributionService
    private let enrichmentService: CaptureEnrichmentService

    // MARK: - Init (Production)

    private init() {
        let performanceRecorder = CapturePerformanceRecorder.shared
        self.captureManager = ScreenCaptureManager.shared
        self.capturePerformanceRecorder = performanceRecorder
        self.settings = AppSettings.shared
        self.appState = AppState.shared
        let presetMgr = PresetManager.shared
        self.processImage = { cgImage, context, smartCrop in
            await ImageProcessor.process(
                cgImage: cgImage, context: context, smartCropEnabled: smartCrop
            )
        }
        self.persistArtifact = { processed, preset in
            _ = try await ScreenshotArtifactCoordinator.shared.saveCapture(
                processed,
                subfolder: preset.subfolder
            )
        }
        let copyToClipboard = makeCapturePipelineCopyToClipboard()
        let saveCaptureAction: SaveCaptureActionFn = { screenshot in
            try await ScreenshotArtifactCoordinator.shared.saveCapture(screenshot)
        }
        let recognizeText: RecognizeTextFn = { cgImage in
            try await OCREngine.recognizeText(in: cgImage)
        }
        self.handlePermissionFailure = {
            await PermissionCoordinator.shared.handleCapturePermissionFailure()
        }
        self.showQuickAccess = { processed in
            QuickAccessOverlay.shared.show(for: processed)
        }
        let playSoundAction: PlaySoundFn = {
            NSSound(named: "Tink")?.play()
        }
        self.postNotification = { name in
            NotificationCenter.default.post(name: name, object: nil)
        }
        let detectContext: DetectContextFn = { ContextDetector.detectContext() }
        let presetForCategory: PresetForCategoryFn = { category in
            presetMgr.presetForCategory(category)
        }
        let presetByName: PresetByNameFn = { name in
            presetMgr.preset(named: name)
        }
        self.selectWindowCapture = makeCapturePipelineSelectWindowCapture()
        self.makeAreaCaptureSession = makeCapturePipelineAreaCaptureSessionFactory(
            performanceRecorder: performanceRecorder
        )
        self.makeFullscreenCaptureSession = makeCapturePipelineFullscreenCaptureSessionFactory(
            performanceRecorder: performanceRecorder
        )
        self.makeWindowCaptureSession = makeCapturePipelineWindowCaptureSessionFactory(
            performanceRecorder: performanceRecorder,
            captureManager: self.captureManager
        )
        self.screenCountProvider = { NSScreen.screens.count }
        self.freezeScreensEnabled = true
        self.enrichmentCoordinator = CaptureEnrichmentCoordinator()
        let services = makeCapturePipelineServices(
            dependencies: ServiceDependencies(
                settings: self.settings,
                appState: self.appState,
                detectContext: detectContext,
                presetForCategory: presetForCategory,
                presetByName: presetByName,
                copyToClipboard: copyToClipboard,
                saveCaptureAction: saveCaptureAction,
                playSoundAction: playSoundAction,
                recognizeText: recognizeText
            ),
            enrichmentCoordinator: self.enrichmentCoordinator
        )
        self.requestResolver = services.requestResolver
        self.enrichmentService = services.enrichmentService
        self.distributionService = services.distributionService
    }

    // MARK: - Init (Testing)

    init(
        settings: AppSettings,
        appState: AppState,
        captureManager: ScreenCaptureManaging?,
        capturePerformanceRecorder: CapturePerformanceRecorder,
        detectContext: @escaping DetectContextFn,
        processImage: @escaping ProcessImageFn,
        saveFile: @escaping SaveFileFn,
        persistArtifact: @escaping PersistArtifactFn,
        copyToClipboard: @escaping CopyToClipboardFn,
        saveCaptureAction: SaveCaptureActionFn? = nil,
        recognizeText: @escaping RecognizeTextFn,
        handlePermissionFailure: @escaping HandlePermissionFailureFn,
        showQuickAccess: @escaping ShowQuickAccessFn,
        playSoundAction: @escaping PlaySoundFn,
        postNotification: @escaping PostNotificationFn,
        presetForCategory: @escaping PresetForCategoryFn,
        presetByName: @escaping PresetByNameFn,
        selectWindowCapture: @escaping SelectWindowCaptureFn = { _ in .cancelled },
        makeAreaCaptureSession: MakeAreaCaptureSessionFn? = nil,
        makeFullscreenCaptureSession: MakeFullscreenCaptureSessionFn? = nil,
        makeWindowCaptureSession: MakeWindowCaptureSessionFn? = nil,
        screenCountProvider: @escaping () -> Int = { NSScreen.screens.count },
        freezeScreensEnabled: Bool = true,
        enrichmentCoordinator: CaptureEnrichmentCoordinator = CaptureEnrichmentCoordinator()
    ) {
        let resolvedCaptureManager = captureManager ?? ScreenCaptureManager.shared
        self.captureManager = resolvedCaptureManager
        self.capturePerformanceRecorder = capturePerformanceRecorder
        self.settings = settings
        self.appState = appState
        self.processImage = processImage
        self.persistArtifact = persistArtifact
        self.handlePermissionFailure = handlePermissionFailure
        self.showQuickAccess = showQuickAccess
        self.postNotification = postNotification
        self.selectWindowCapture = selectWindowCapture
        self.makeAreaCaptureSession = makeAreaCaptureSession ?? { session, onSelection, onCancel, onFirstInteraction in
            AreaCaptureSessionCoordinator(
                session: session,
                performanceRecorder: capturePerformanceRecorder,
                cursorController: CaptureCursorController(),
                onSelection: onSelection,
                onCancel: onCancel,
                onFirstInteraction: onFirstInteraction
            )
        }
        self.makeFullscreenCaptureSession = makeFullscreenCaptureSession ?? { session, onSelection, onCancel in
            FullscreenCaptureSessionCoordinator(
                session: session,
                performanceRecorder: capturePerformanceRecorder,
                cursorController: CaptureCursorController(),
                onSelection: onSelection,
                onCancel: onCancel
            )
        }
        self.makeWindowCaptureSession = makeWindowCaptureSession ?? { session, prewarmContent, selectWindowCapture in
            WindowCaptureSessionCoordinator(
                session: session,
                performanceRecorder: capturePerformanceRecorder,
                hasWarmContent: resolvedCaptureManager.hasWarmWindowShareableContent,
                prewarmContent: {
                    await prewarmContent()
                },
                pickWindow: selectWindowCapture
            )
        }
        self.screenCountProvider = screenCountProvider
        self.freezeScreensEnabled = freezeScreensEnabled
        self.enrichmentCoordinator = enrichmentCoordinator
        let resolvedSaveCaptureAction = saveCaptureAction ?? { screenshot in
            let presetName = screenshot.presetName
            let preset = presetName.flatMap(presetByName) ?? CapturePreset(name: "Quick Capture")
            try await persistArtifact(screenshot, preset)
            guard let url = screenshot.filePath else {
                throw CaptureError.noContent(source: "Saved capture artifact")
            }
            return url
        }
        let services = makeCapturePipelineServices(
            dependencies: ServiceDependencies(
                settings: settings,
                appState: appState,
                detectContext: detectContext,
                presetForCategory: presetForCategory,
                presetByName: presetByName,
                copyToClipboard: copyToClipboard,
                saveCaptureAction: resolvedSaveCaptureAction,
                playSoundAction: playSoundAction,
                recognizeText: recognizeText
            ),
            enrichmentCoordinator: enrichmentCoordinator
        )
        self.requestResolver = services.requestResolver
        self.enrichmentService = services.enrichmentService
        self.distributionService = services.distributionService
    }

    func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }

    func isSameObject(_ lhs: AnyObject?, _ rhs: AnyObject?) -> Bool {
        guard let lhs, let rhs else { return false }
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
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
            let request = requestResolver.resolve(mode: mode)

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
                cgImage: cgImage,
                request: request
            )
            let hasDeferredEnrichment = settings.autoSaveToDisk
            appState.setCapturePreviewPhase(
                hasDeferredEnrichment ? .enrichmentPending : .rawPreviewReady,
                for: processed.id
            )
            let previewStart = CFAbsoluteTimeGetCurrent()
            appState.lastScreenshot = processed
            appState.statusMessage = "Captured!"
            showQuickAccess(processed)
            let previewDuration = elapsedMilliseconds(since: previewStart)
            if let performanceSession {
                capturePerformanceRecorder.recordDuration(
                    .previewPresentationDuration,
                    milliseconds: previewDuration,
                    in: performanceSession
                )
                capturePerformanceRecorder.mark(.rawPreviewVisible, in: performanceSession)
            }
            postNotification(.captureCompleted)

            let totalDuration = self.elapsedMilliseconds(since: pipelineStart)
            logger.info(
                "Capture pipeline finished in \(totalDuration, privacy: .public) ms"
            )
            recordMetric(stage: .total, milliseconds: totalDuration)
            await distributeCapture(
                processed,
                preset: preset,
                performanceSession: performanceSession
            )

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
            appState.isCapturing = false
            await handlePermissionFailure()
            if let performanceSession {
                capturePerformanceRecorder.finishSession(performanceSession)
            }
        } catch {
            let logMessage = captureFailureLogMessage(for: error)
            logger.error("Capture failed: \(logMessage, privacy: .public)")
            appState.statusMessage = captureFailureStatusMessage(for: error)
            if let performanceSession {
                capturePerformanceRecorder.finishSession(performanceSession)
            }
        }

        if appState.isCapturing {
            appState.isCapturing = false
        }
    }

    func captureFailureStatusMessage(
        for error: Error,
        operation: String = "Capture"
    ) -> String {
        if let captureError = normalizedCaptureError(
            from: error,
            operation: operation
        ) {
            return captureError.userMessage
        }

        return "\(operation) failed before an image was produced. Try again. "
            + "If it keeps happening, restart Caloura."
    }

    func captureFailureLogMessage(
        for error: Error,
        operation: String = "Capture"
    ) -> String {
        if let captureError = normalizedCaptureError(
            from: error,
            operation: operation
        ) {
            return captureError.logMessage
        }

        return "\(type(of: error)): \(error.localizedDescription)"
    }

    func normalizedCaptureError(
        from error: Error,
        operation: String
    ) -> CaptureError? {
        if let captureError = error as? CaptureError {
            return captureError
        }
        if error is TimeoutError {
            return .timeout(operation: operation)
        }
        return nil
    }

    // MARK: - Process Capture

    private func processCapture(
        cgImage: CGImage,
        request: CaptureRequestResolution
    ) async -> (ProcessedScreenshot, CapturePreset) {
        let processStart = CFAbsoluteTimeGetCurrent()
        let processed = await processImage(
            cgImage,
            request.captureContext,
            request.smartCropEnabled
        )
        let processDuration = elapsedMilliseconds(since: processStart)
        logger.debug(
            "Image processing completed in \(processDuration, privacy: .public) ms"
        )
        recordMetric(stage: .process, milliseconds: processDuration)
        processed.presetName = request.preset.name

        return (processed, request.preset)
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
                try await distributionService.copy(processed, using: preset.copyMode)
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
            distributionService.playCaptureSound()
        }
    }

    // MARK: - History + OCR

    func addToHistoryWithOCR(_ processed: ProcessedScreenshot) {
        enrichmentService.enqueueEnrichment(for: processed)
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

@MainActor
private func makeCapturePipelineCopyToClipboard() -> CapturePipeline.CopyToClipboardFn {
    { processed, copyMode in
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
}

extension CapturePipeline {
    func replaceOverlayWindows(_ windows: [CaptureOverlayWindow]) {
        overlayWindows = windows
    }

    func clearOverlayWindows() {
        overlayWindows = []
    }

    func replaceScreenOverlays(_ overlays: [ScreenSelectionOverlayWindow]) {
        screenOverlays = overlays
    }

    func clearScreenOverlays() {
        screenOverlays = []
    }

    func replaceAreaCaptureSession(_ session: (any AreaCaptureSessionHandling)?) {
        areaCaptureSession = session
    }

    func replaceFullscreenCaptureSession(_ session: (any FullscreenCaptureSessionHandling)?) {
        fullscreenCaptureSession = session
    }

    func replaceDelayedCaptureTask(_ task: Task<Void, Never>?) {
        delayedCaptureTask = task
    }
}

@MainActor
private func makeCapturePipelineSelectWindowCapture() -> CapturePipeline.SelectWindowCaptureFn {
    { onPresented in
        let result = await WindowPickerManager.shared.pickWindow(onPresented: onPresented)
        switch result {
        case .selected(let filter):
            return .selected {
                try await ScreenCaptureManager.shared.captureWindow(filter: filter)
            }
        case .cancelled:
            return .cancelled
        case .failedToStart:
            return .failedToStart
        }
    }
}

@MainActor
private func makeCapturePipelineAreaCaptureSessionFactory(
    performanceRecorder: CapturePerformanceRecorder
) -> CapturePipeline.MakeAreaCaptureSessionFn {
    { session, onSelection, onCancel, onFirstInteraction in
        AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            cursorController: CaptureCursorController(),
            onSelection: onSelection,
            onCancel: onCancel,
            onFirstInteraction: onFirstInteraction
        )
    }
}

@MainActor
private func makeCapturePipelineFullscreenCaptureSessionFactory(
    performanceRecorder: CapturePerformanceRecorder
) -> CapturePipeline.MakeFullscreenCaptureSessionFn {
    { session, onSelection, onCancel in
        FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            cursorController: CaptureCursorController(),
            onSelection: onSelection,
            onCancel: onCancel
        )
    }
}

@MainActor
private func makeCapturePipelineWindowCaptureSessionFactory(
    performanceRecorder: CapturePerformanceRecorder,
    captureManager: ScreenCaptureManaging
) -> CapturePipeline.MakeWindowCaptureSessionFn {
    { session, prewarmContent, selectWindowCapture in
        WindowCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            hasWarmContent: captureManager.hasWarmWindowShareableContent,
            prewarmContent: {
                await prewarmContent()
            },
            pickWindow: selectWindowCapture
        )
    }
}

@MainActor
private func makeCapturePipelineServices(
    dependencies: CapturePipeline.ServiceDependencies,
    enrichmentCoordinator: CaptureEnrichmentCoordinator
) -> CapturePipeline.Services {
    let requestResolver = CaptureRequestResolver(
        settings: dependencies.settings,
        detectContext: dependencies.detectContext,
        presetForCategory: dependencies.presetForCategory,
        presetByName: dependencies.presetByName
    )
    let enrichmentService = CaptureEnrichmentService(
        appState: dependencies.appState,
        settings: dependencies.settings,
        recognizeText: dependencies.recognizeText,
        enrichmentCoordinator: enrichmentCoordinator
    )
    let distributionService = CaptureDistributionService(
        appState: dependencies.appState,
        copyToClipboard: dependencies.copyToClipboard,
        saveCapture: dependencies.saveCaptureAction,
        playSound: dependencies.playSoundAction,
        enqueueEnrichment: { screenshot in
            enrichmentService.enqueueEnrichment(for: screenshot)
        },
        dispatchCommand: { command in
            AppCommandRouter.shared.dispatch(command)
        },
        showTip: { tip in
            OnboardingTipsController.shared.showIfNeeded(tip)
        },
        dismissQuickAccess: {
            QuickAccessOverlay.shared.dismiss()
        }
    )

    return .init(
        requestResolver: requestResolver,
        enrichmentService: enrichmentService,
        distributionService: distributionService
    )
}
