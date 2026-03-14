import AppKit
import CoreGraphics
import os.log

private let scrollCaptureLogger = Logger(
    subsystem: "com.caloura.app",
    category: "ScrollCapture"
)

private struct ScrollCaptureStart {
    let viewport: ScrollCaptureViewport
    let mode: ScrollCaptureMode
    let frames: [ScrollCaptureFrame]
    let scrollDirection: Int
    let usedManualFallback: Bool
}

private struct ScrollCaptureOutcome {
    let terminationReason: ScrollTerminationReason
    let usedManualFallback: Bool
}

extension ScrollCaptureEngine {
    func capture(
        _ request: Request,
        control: ScrollCaptureControl = ScrollCaptureControl(),
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        onProgress: @escaping @MainActor @Sendable (ScrollCaptureProgress) -> Void
    ) async -> Result {
        let session = Session(
            request: request,
            control: control,
            captureFrame: captureFrame,
            onProgress: onProgress
        )
        var diagnostics = ScrollCaptureDiagnostics(targetAppName: request.targetAppName)

        await sendProgress(
            ProgressUpdate(
                phase: .preparing,
                mode: request.config.modeBias == .manualPreferred ? .manual : .automatic,
                frames: 0,
                estimatedHeight: 0,
                status: "Preparing scroll capture",
                allowManualSwitch: request.config.allowManualFallback
            ),
            session: session
        )

        do {
            let start = try await beginCapture(session: session, diagnostics: &diagnostics)
            var frames = start.frames
            let outcome = try await completeCapture(
                start: start,
                frames: &frames,
                session: session,
                diagnostics: &diagnostics
            )
            return try await finalizeCapture(
                frames: frames,
                outcome: outcome,
                session: session,
                diagnostics: &diagnostics
            )
        } catch is CancellationError {
            scrollDriver.finishGesture()
            return .cancelled
        } catch {
            scrollDriver.finishGesture()
            return await failureResult(error, diagnostics: diagnostics, session: session)
        }
    }

    private func beginCapture(
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> ScrollCaptureStart {
        let detection = viewportDetector.detectViewport(
            in: session.request.region,
            geometry: session.request.geometry
        )
        let viewport = try resolveViewport(
            detection: detection,
            geometry: session.request.geometry,
            config: session.request.config,
            diagnostics: &diagnostics
        )
        let mode = initialMode(for: detection, config: session.request.config)
        diagnostics.mode = mode

        if session.request.config.scrollToTop && mode == .automatic {
            await sendProgress(
                ProgressUpdate(
                    phase: .preparing,
                    mode: mode,
                    frames: 0,
                    estimatedHeight: 0,
                    status: "Scrolling to top",
                    allowManualSwitch: session.request.config.allowManualFallback
                ),
                session: session
            )
            try await scrollToTopIfNeeded(scrollBar: viewport.verticalScrollBar)
        }

        guard let firstPrepared = try await prepareCapturedFrame(
            rect: viewport.captureRect,
            captureFrame: session.captureFrame
        ) else {
            throw ScrollCaptureError.framePreparationFailed
        }

        let progressStatus = mode == .automatic ? "Viewport locked" : "Manual capture ready"
        let progressPhase: ScrollCapturePhase = mode == .automatic
            ? .detectingViewport
            : .manualCapturing

        var frames = [
            ScrollCaptureFrame(
                preparedFrame: firstPrepared,
                placement: ScrollFramePlacement(originY: 0, displacementFromPrevious: 0),
                unstableBands: [],
                stickyHeaderHeight: 0,
                displacementConfidence: 1.0
            )
        ]

        await sendProgress(
            ProgressUpdate(
                phase: progressPhase,
                mode: mode,
                frames: frames.count,
                estimatedHeight: frames.last?.estimatedBottom ?? 0,
                status: progressStatus,
                allowManualSwitch: session.request.config.allowManualFallback
            ),
            session: session
        )

        var scrollDirection = initialScrollDirection(for: session.request.config)
        if mode == .automatic {
            let calibration = try await calibrateDirection(
                viewport: viewport,
                baselineFrame: firstPrepared,
                currentDirection: scrollDirection,
                session: session,
                diagnostics: &diagnostics
            )
            scrollDirection = calibration.scrollDirection
            frames[0] = ScrollCaptureFrame(
                preparedFrame: calibration.baselineFrame,
                placement: ScrollFramePlacement(originY: 0, displacementFromPrevious: 0),
                unstableBands: [],
                stickyHeaderHeight: 0,
                displacementConfidence: 1.0
            )
        }

        return ScrollCaptureStart(
            viewport: viewport,
            mode: mode,
            frames: frames,
            scrollDirection: scrollDirection,
            usedManualFallback: mode == .manual
        )
    }

    private func completeCapture(
        start: ScrollCaptureStart,
        frames: inout [ScrollCaptureFrame],
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> ScrollCaptureOutcome {
        var usedManualFallback = start.usedManualFallback

        if start.mode == .automatic {
            switch try await runAutomaticCapture(
                frames: &frames,
                viewport: start.viewport,
                scrollDirection: start.scrollDirection,
                session: session,
                diagnostics: &diagnostics
            ) {
            case .completed(let reason):
                return ScrollCaptureOutcome(
                    terminationReason: reason,
                    usedManualFallback: usedManualFallback
                )
            case .fallbackToManual(let trigger):
                diagnostics.fallbackTrigger = trigger
                diagnostics.mode = .manual
                usedManualFallback = true
            }
        }

        let terminationReason = try await runManualCapture(
            frames: &frames,
            viewport: start.viewport,
            session: session,
            diagnostics: &diagnostics
        )
        return ScrollCaptureOutcome(
            terminationReason: terminationReason,
            usedManualFallback: usedManualFallback
        )
    }

    private func finalizeCapture(
        frames: [ScrollCaptureFrame],
        outcome: ScrollCaptureOutcome,
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> Result {
        scrollDriver.finishGesture()

        guard let firstFrame = frames.first else {
            throw ScrollCaptureError.noFramesCaptured
        }

        diagnostics.acceptedFrameCount = frames.count
        diagnostics.terminationReason = outcome.terminationReason

        await sendProgress(
            ProgressUpdate(
                phase: .finalizing,
                mode: diagnostics.mode,
                frames: frames.count,
                estimatedHeight: frames.last?.estimatedBottom ?? firstFrame.height,
                status: "Finalizing capture",
                allowManualSwitch: false
            ),
            session: session
        )

        let finalImage: CGImage
        if frames.count == 1 {
            finalImage = firstFrame.image
        } else {
            let stitched = try stitcher.stitch(
                frames: frames,
                maxCanvasHeight: session.request.config.maxHeightPx
            )
            diagnostics.seamRepairCount = stitched.seamRepairCount
            finalImage = stitched.image
        }

        await sendProgress(
            ProgressUpdate(
                phase: .completed,
                mode: diagnostics.mode,
                frames: frames.count,
                estimatedHeight: min(session.request.config.maxHeightPx, finalImage.height),
                status: "Scroll capture complete",
                allowManualSwitch: false
            ),
            session: session
        )

        let mode = diagnostics.mode.rawValue
        let viewportConfidence = diagnostics.viewportConfidence
        let fallbackTrigger = diagnostics.fallbackTrigger ?? "none"

        scrollCaptureLogger.info(
            """
            Scroll capture complete mode=\(mode, privacy: .public) \
            frames=\(frames.count, privacy: .public) height=\(finalImage.height, privacy: .public) \
            viewportConfidence=\(viewportConfidence, format: .fixed(precision: 2)) \
            fallback=\(fallbackTrigger, privacy: .public) \
            reason=\(outcome.terminationReason.rawValue, privacy: .public)
            """
        )

        return .success(
            ScrollCaptureOutput(
                image: finalImage,
                mode: diagnostics.mode,
                terminationReason: outcome.terminationReason,
                usedManualFallback: outcome.usedManualFallback,
                diagnostics: diagnostics
            )
        )
    }

    private func failureResult(
        _ error: Error,
        diagnostics: ScrollCaptureDiagnostics,
        session: Session
    ) async -> Result {
        await sendProgress(
            ProgressUpdate(
                phase: .failed,
                mode: diagnostics.mode,
                frames: diagnostics.acceptedFrameCount,
                estimatedHeight: 0,
                status: failureStatusMessage(for: error),
                allowManualSwitch: false
            ),
            session: session
        )
        return .failed(error)
    }

    private func failureStatusMessage(for error: Error) -> String {
        if let scrollError = error as? ScrollCaptureError {
            return scrollError.userMessage
        }
        if let captureError = error as? CaptureError {
            return captureError.userMessage
        }
        if error is TimeoutError {
            return CaptureError.timeout(operation: "Scroll capture").userMessage
        }
        return "Scroll capture failed. Try again. If it keeps happening, restart Caloura."
    }

    private func initialMode(
        for detection: ScrollViewportDetection,
        config: Config
    ) -> ScrollCaptureMode {
        if detection.detectedViewport == nil || detection.isAmbiguous {
            return .manual
        }

        return config.modeBias == .manualPreferred ? .manual : .automatic
    }

    private func resolveViewport(
        detection: ScrollViewportDetection,
        geometry: ScrollScreenGeometry,
        config: Config,
        diagnostics: inout ScrollCaptureDiagnostics
    ) throws -> ScrollCaptureViewport {
        if let viewport = detection.detectedViewport, !detection.isAmbiguous {
            diagnostics.viewportConfidence = viewport.confidence
            diagnostics.usedAutoDetectedViewport = viewport.usedAutoDetectedViewport
            return viewport
        }

        let fallbackRect = ScrollCaptureHelpers.pixelAlignedRect(
            detection.fallbackRect,
            scale: geometry.scale,
            within: geometry.localBounds
        )
        guard fallbackRect.width > 0, fallbackRect.height > 0 else {
            throw ScrollCaptureError.noScrollableViewport
        }

        if detection.isAmbiguous || config.allowManualFallback {
            diagnostics.viewportConfidence = detection.detectedViewport?.confidence ?? 0
            diagnostics.usedAutoDetectedViewport = false
            return ScrollCaptureViewport(
                captureRect: fallbackRect,
                confidence: diagnostics.viewportConfidence,
                usedAutoDetectedViewport: false,
                scrollElement: detection.detectedViewport?.scrollElement,
                verticalScrollBar: detection.detectedViewport?.verticalScrollBar
            )
        }

        throw ScrollCaptureError.noScrollableViewport
    }

    private func prepareCapturedFrame(
        rect: CGRect,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage
    ) async throws -> ScrollCaptureHelpers.PreparedFrame? {
        let image = try await captureFrame(rect)
        return autoreleasepool {
            ScrollCaptureHelpers.prepareFrame(image)
        }
    }

    private func calibrateDirection(
        viewport: ScrollCaptureViewport,
        baselineFrame: ScrollCaptureHelpers.PreparedFrame,
        currentDirection: Int,
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> (
        baselineFrame: ScrollCaptureHelpers.PreparedFrame,
        scrollDirection: Int
    ) {
        let maximumUsefulDisplacement = max(40, baselineFrame.height - 32)
        let trialDisplacement = min(
            maximumUsefulDisplacement,
            max(40, Int(Double(baselineFrame.height) * 0.25))
        )
        let trialPixels = currentDirection * trialDisplacement

        await sendProgress(
            ProgressUpdate(
                phase: .calibrating,
                mode: .automatic,
                frames: 1,
                estimatedHeight: baselineFrame.height,
                status: "Calibrating scroll direction",
                allowManualSwitch: session.request.config.allowManualFallback
            ),
            session: session
        )

        scrollDriver.scroll(by: trialPixels)
        let forwardProbe = try await settling.settle(
            request: ScrollSettleRequest(
                region: viewport.captureRect,
                previousAcceptedFrame: baselineFrame,
                expectedDisplacement: trialDisplacement,
                stickyHeaderHeight: 0,
                mode: .automatic
            ),
            captureFrame: session.captureFrame,
            displacementEstimator: displacementEstimator
        )

        let forwardEstimate = forwardProbe.map {
            displacementEstimator.estimate(
                previous: baselineFrame,
                current: $0.preparedFrame,
                options: .calibration(expectedDisplacement: trialDisplacement)
            )
        }

        scrollDriver.scroll(by: -trialPixels)
        let returnedBaseline = try await settling.settle(
            request: ScrollSettleRequest(
                region: viewport.captureRect,
                previousAcceptedFrame: forwardProbe?.preparedFrame ?? baselineFrame,
                expectedDisplacement: trialDisplacement,
                stickyHeaderHeight: 0,
                mode: .automatic
            ),
            captureFrame: session.captureFrame,
            displacementEstimator: displacementEstimator
        )?.preparedFrame ?? baselineFrame

        let finalDirection: Int
        if let forwardEstimate,
           forwardEstimate.confidence >= ScrollCaptureThresholds.minimumAlignmentConfidence,
           forwardEstimate.displacement <= -ScrollCaptureThresholds.minimumMeaningfulDisplacement {
            finalDirection = -currentDirection
        } else {
            finalDirection = currentDirection
        }

        diagnostics.stepCount += 1
        return (returnedBaseline, finalDirection)
    }

    func sendProgress(
        _ update: ProgressUpdate,
        session: Session
    ) async {
        await session.onProgress(update.progress)
    }
}
