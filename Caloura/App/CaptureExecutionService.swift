import AppKit
import os.log

@MainActor
final class CaptureExecutionService {
    typealias ProcessImageFn = CapturePipeline.ProcessImageFn
    typealias PersistArtifactFn = CapturePipeline.PersistArtifactFn
    typealias HandlePermissionFailureFn = CapturePipeline.HandlePermissionFailureFn
    typealias ShowQuickAccessFn = CapturePipeline.ShowQuickAccessFn
    typealias PostNotificationFn = CapturePipeline.PostNotificationFn

    private enum SaveOutcome {
        case saved
        case failed
    }

    private let settings: AppSettings
    private let appState: AppState
    private let requestResolver: CaptureRequestResolver
    private let distributionService: CaptureDistributionService
    private let enrichmentService: CaptureEnrichmentService
    private let capturePerformanceRecorder: CapturePerformanceRecorder
    private let processImage: ProcessImageFn
    private let persistArtifact: PersistArtifactFn
    private let handlePermissionFailure: HandlePermissionFailureFn
    private let showQuickAccess: ShowQuickAccessFn
    private let postNotification: PostNotificationFn
    private let metricsRecorder: CaptureMetricsRecorder
    private let logger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")

    init(
        settings: AppSettings,
        appState: AppState,
        requestResolver: CaptureRequestResolver,
        distributionService: CaptureDistributionService,
        enrichmentService: CaptureEnrichmentService,
        capturePerformanceRecorder: CapturePerformanceRecorder,
        processImage: @escaping ProcessImageFn,
        persistArtifact: @escaping PersistArtifactFn,
        handlePermissionFailure: @escaping HandlePermissionFailureFn,
        showQuickAccess: @escaping ShowQuickAccessFn,
        postNotification: @escaping PostNotificationFn,
        metricsRecorder: CaptureMetricsRecorder
    ) {
        self.settings = settings
        self.appState = appState
        self.requestResolver = requestResolver
        self.distributionService = distributionService
        self.enrichmentService = enrichmentService
        self.capturePerformanceRecorder = capturePerformanceRecorder
        self.processImage = processImage
        self.persistArtifact = persistArtifact
        self.handlePermissionFailure = handlePermissionFailure
        self.showQuickAccess = showQuickAccess
        self.postNotification = postNotification
        self.metricsRecorder = metricsRecorder
    }

    func performCapture(
        mode: CaptureMode,
        performanceSession: CapturePerformanceRecorder.Session? = nil,
        capture: () async throws -> CGImage
    ) async {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        logger.info("Starting capture: mode=\(mode.rawValue)")

        do {
            let request = requestResolver.resolve(mode: mode)
            let cgImage = try await captureImage(
                with: capture,
                performanceSession: performanceSession
            )
            let (processed, preset) = await processCapture(
                cgImage: cgImage,
                request: request
            )
            publishRawPreview(
                for: processed,
                performanceSession: performanceSession
            )

            let totalDuration = metricsRecorder.elapsedMilliseconds(since: pipelineStart)
            logger.info(
                "Capture pipeline finished in \(totalDuration, privacy: .public) ms"
            )
            metricsRecorder.recordMetric(stage: .total, milliseconds: totalDuration)

            await distributeCapture(
                processed,
                preset: preset,
                performanceSession: performanceSession
            )

            if settings.autoSaveToDisk {
                scheduleDeferredSaveAndEnrichment(
                    for: processed,
                    preset: preset,
                    performanceSession: performanceSession
                )
            } else {
                appState.setCapturePreviewPhase(.enrichmentComplete, for: processed.id)
                finishPerformanceSession(performanceSession)
            }

            appState.isCapturing = false
            appState.currentCaptureRequestID = nil
        } catch CaptureError.noPermission {
            await handlePermissionDenied(
                mode: mode,
                performanceSession: performanceSession
            )
        } catch {
            handleCaptureFailure(error, performanceSession: performanceSession)
        }

        if appState.isCapturing {
            appState.isCapturing = false
        }
        appState.currentCaptureRequestID = nil
    }

    func enqueueEnrichment(for processed: ProcessedScreenshot) {
        enrichmentService.enqueueEnrichment(for: processed)
    }

    func captureFailureStatusMessage(
        for error: Error,
        operation: String = "Capture"
    ) -> String {
        if let captureError = normalizedCaptureError(from: error, operation: operation) {
            return captureError.userMessage
        }

        return "\(operation) failed before an image was produced. Try again. "
            + "If it keeps happening, restart Caloura."
    }

    func captureFailureLogMessage(
        for error: Error,
        operation: String = "Capture"
    ) -> String {
        if let captureError = normalizedCaptureError(from: error, operation: operation) {
            return captureError.logMessage
        }

        return "\(type(of: error)): \(error.localizedDescription)"
    }

    private func normalizedCaptureError(
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

    private func captureImage(
        with capture: () async throws -> CGImage,
        performanceSession: CapturePerformanceRecorder.Session?
    ) async throws -> CGImage {
        let captureStart = CFAbsoluteTimeGetCurrent()
        let cgImage = try await capture()
        let captureDuration = metricsRecorder.elapsedMilliseconds(since: captureStart)
        logger.info("Capture succeeded: \(cgImage.width)x\(cgImage.height)")
        logger.debug(
            "Capture stage completed in \(captureDuration, privacy: .public) ms"
        )
        metricsRecorder.recordMetric(stage: .capture, milliseconds: captureDuration)
        if let performanceSession {
            capturePerformanceRecorder.recordDuration(
                .screenshotDuration,
                milliseconds: captureDuration,
                in: performanceSession
            )
            capturePerformanceRecorder.mark(.captureImageReady, in: performanceSession)
        }
        return cgImage
    }

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
        let processDuration = metricsRecorder.elapsedMilliseconds(since: processStart)
        logger.debug(
            "Image processing completed in \(processDuration, privacy: .public) ms"
        )
        metricsRecorder.recordMetric(stage: .process, milliseconds: processDuration)
        processed.presetName = request.preset.name

        return (processed, request.preset)
    }

    private func publishRawPreview(
        for processed: ProcessedScreenshot,
        performanceSession: CapturePerformanceRecorder.Session?
    ) {
        let hasDeferredEnrichment = settings.autoSaveToDisk
        appState.setCapturePreviewPhase(
            hasDeferredEnrichment ? .enrichmentPending : .rawPreviewReady,
            for: processed.id
        )

        let previewStart = CFAbsoluteTimeGetCurrent()
        appState.lastScreenshot = processed
        appState.statusMessage = "Captured!"
        showQuickAccess(processed)
        let previewDuration = metricsRecorder.elapsedMilliseconds(since: previewStart)
        if let performanceSession {
            capturePerformanceRecorder.recordDuration(
                .previewPresentationDuration,
                milliseconds: previewDuration,
                in: performanceSession
            )
            capturePerformanceRecorder.mark(.rawPreviewVisible, in: performanceSession)
        }
        var userInfo: [AnyHashable: Any] = [:]
        if let requestID = appState.currentCaptureRequestID {
            userInfo[AppNotificationUserInfoKey.captureRequestID] = requestID
        }
        postNotification(.captureCompleted, userInfo)
    }

    private func scheduleDeferredSaveAndEnrichment(
        for processed: ProcessedScreenshot,
        preset: CapturePreset,
        performanceSession: CapturePerformanceRecorder.Session?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let saveOutcome = await self.saveToDisk(
                processed,
                preset: preset,
                performanceSession: performanceSession
            )
            if saveOutcome == .saved {
                self.enqueueEnrichment(for: processed)
            } else {
                self.appState.setCapturePreviewPhase(.rawPreviewReady, for: processed.id)
            }
            self.finishPerformanceSession(performanceSession)
        }
    }

    private func saveToDisk(
        _ processed: ProcessedScreenshot,
        preset: CapturePreset,
        performanceSession: CapturePerformanceRecorder.Session?
    ) async -> SaveOutcome {
        let saveStart = CFAbsoluteTimeGetCurrent()
        do {
            try await persistArtifact(processed, preset)
            let saveDuration = metricsRecorder.elapsedMilliseconds(since: saveStart)
            logger.debug(
                "Disk save completed in \(saveDuration, privacy: .public) ms"
            )
            metricsRecorder.recordMetric(stage: .save, milliseconds: saveDuration)
            if let performanceSession {
                capturePerformanceRecorder.recordDuration(
                    .saveComplete,
                    milliseconds: saveDuration,
                    in: performanceSession
                )
            }
            return .saved
        } catch {
            let description = error.localizedDescription
            logger.error("File save failed: \(description, privacy: .public)")
            appState.statusMessage = "Save failed: \(description)"
            return .failed
        }
    }

    private func distributeCapture(
        _ processed: ProcessedScreenshot,
        preset: CapturePreset,
        performanceSession: CapturePerformanceRecorder.Session?
    ) async {
        if settings.autoCopyToClipboard {
            let clipboardStart = CFAbsoluteTimeGetCurrent()
            do {
                try await distributionService.copy(processed, using: preset.copyMode)
                let clipboardDuration = metricsRecorder.elapsedMilliseconds(since: clipboardStart)
                logger.debug(
                    "Clipboard stage completed in \(clipboardDuration, privacy: .public) ms"
                )
                metricsRecorder.recordMetric(stage: .clipboard, milliseconds: clipboardDuration)
                if let performanceSession {
                    capturePerformanceRecorder.recordDuration(
                        .clipboardComplete,
                        milliseconds: clipboardDuration,
                        in: performanceSession
                    )
                }
            } catch {
                let description = error.localizedDescription
                logger.error("Clipboard copy failed: \(description, privacy: .public)")
                appState.statusMessage = "Clipboard failed: \(description)"
            }
        }

        if settings.playCaptureSound {
            distributionService.playCaptureSound()
        }
    }

    private func handlePermissionDenied(
        mode: CaptureMode,
        performanceSession: CapturePerformanceRecorder.Session?
    ) async {
        logger.warning("Capture failed: no permission")
        appState.isCapturing = false
        await handlePermissionFailure(mode)
        finishPerformanceSession(performanceSession)
    }

    private func handleCaptureFailure(
        _ error: Error,
        performanceSession: CapturePerformanceRecorder.Session?
    ) {
        let logMessage = captureFailureLogMessage(for: error)
        logger.error("Capture failed: \(logMessage, privacy: .public)")
        appState.statusMessage = captureFailureStatusMessage(for: error)
        finishPerformanceSession(performanceSession)
    }

    private func finishPerformanceSession(
        _ performanceSession: CapturePerformanceRecorder.Session?
    ) {
        guard let performanceSession else { return }
        capturePerformanceRecorder.finishSession(performanceSession)
    }
}
