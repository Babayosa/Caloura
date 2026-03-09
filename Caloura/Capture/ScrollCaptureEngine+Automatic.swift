import Foundation

private enum AutomaticSettlingResult {
    case settled(AutomaticStep)
    case noFrame
    case unstable
}

private enum AutomaticStepDecision {
    case continueLoop
    case completed(ScrollTerminationReason)
    case fallbackToManual(String)
}

private struct AutomaticLoopState {
    let maximumUsefulDisplacement: Int
    var requestedDisplacement: Int
    var noProgressCount = 0
    var lowConfidenceCount = 0
    var unstableBandCount = 0

    init(firstFrame: ScrollCaptureFrame) {
        maximumUsefulDisplacement = max(
            40,
            firstFrame.height - max(24, firstFrame.stickyHeaderHeight + 8)
        )
        requestedDisplacement = clamp(
            Int(Double(firstFrame.height) * 0.72),
            min: 60,
            max: maximumUsefulDisplacement
        )
    }
}

private struct AutomaticStep {
    let previousFrame: ScrollCaptureFrame
    let previousBarValue: Double?
    let currentBarValue: Double?
    let settled: ScrollSettledFrame
}

private struct AutomaticEstimateResult {
    let estimate: ScrollDisplacementEstimate
    let stickyHeaderHeight: Int
}

extension ScrollCaptureEngine {
    func runAutomaticCapture(
        frames: inout [ScrollCaptureFrame],
        viewport: ScrollCaptureViewport,
        scrollDirection: Int,
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> AutomaticCaptureResult {
        let maxLoops = 300
        var state = AutomaticLoopState(firstFrame: frames[0])

        for _ in 0..<maxLoops {
            try Task.checkCancellation()

            if session.request.config.allowManualFallback,
               await session.control.consumeManualRequest() {
                return .fallbackToManual("user_switch")
            }

            let previousFrame = frames[frames.count - 1]
            let settlingResult = try await settleAutomaticFrame(
                viewport: viewport,
                previousFrame: previousFrame,
                requestedDisplacement: state.requestedDisplacement,
                scrollDirection: scrollDirection,
                session: session
            )

            switch settlingResult {
            case .settled(let step):
                let decision = try await handleAutomaticStep(
                    step,
                    frames: &frames,
                    state: &state,
                    session: session,
                    diagnostics: &diagnostics
                )
                switch decision {
                case .continueLoop:
                    continue
                case .completed(let reason):
                    return .completed(reason)
                case .fallbackToManual(let trigger):
                    return .fallbackToManual(trigger)
                }
            case .noFrame:
                if session.request.config.allowManualFallback {
                    return .fallbackToManual("no_settled_frame")
                }
                throw ScrollCaptureError.unstableScrolling
            case .unstable:
                if session.request.config.allowManualFallback {
                    return .fallbackToManual("unstable_scroll")
                }
                throw ScrollCaptureError.unstableScrolling
            }
        }

        return .completed(.maxHeightReached)
    }

    private func settleAutomaticFrame(
        viewport: ScrollCaptureViewport,
        previousFrame: ScrollCaptureFrame,
        requestedDisplacement: Int,
        scrollDirection: Int,
        session: Session
    ) async throws -> AutomaticSettlingResult {
        let previousBarValue = viewport.verticalScrollBar.map(axScrollValue)
        scrollDriver.scroll(by: scrollDirection * requestedDisplacement)

        var settled = try await settling.settle(
            request: ScrollSettleRequest(
                region: viewport.captureRect,
                previousAcceptedFrame: previousFrame.preparedFrame,
                expectedDisplacement: requestedDisplacement,
                stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                mode: .automatic
            ),
            captureFrame: session.captureFrame,
            displacementEstimator: displacementEstimator
        )

        if settled?.stabilized == false {
            settled = try await settling.settle(
                request: ScrollSettleRequest(
                    region: viewport.captureRect,
                    previousAcceptedFrame: previousFrame.preparedFrame,
                    expectedDisplacement: requestedDisplacement,
                    stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                    mode: .automatic
                ),
                captureFrame: session.captureFrame,
                displacementEstimator: displacementEstimator
            )
        }

        guard let settled else {
            return .noFrame
        }
        guard settled.stabilized else {
            return .unstable
        }

        return .settled(
            AutomaticStep(
                previousFrame: previousFrame,
                previousBarValue: previousBarValue,
                currentBarValue: viewport.verticalScrollBar.map(axScrollValue),
                settled: settled
            )
        )
    }

    private func handleAutomaticStep(
        _ step: AutomaticStep,
        frames: inout [ScrollCaptureFrame],
        state: inout AutomaticLoopState,
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> AutomaticStepDecision {
        let analysis = automaticEstimate(
            previousFrame: step.previousFrame,
            settled: step.settled,
            requestedDisplacement: state.requestedDisplacement
        )
        diagnostics.stepCount += 1

        if let fallbackTrigger = automaticFallbackTrigger(
            estimate: analysis.estimate,
            unstableBands: step.settled.unstableBands,
            allowManualFallback: session.request.config.allowManualFallback,
            state: &state
        ) {
            return .fallbackToManual(fallbackTrigger)
        }

        if !analysis.estimate.isMeaningful {
            return try handleNoAutomaticProgress(
                step: step,
                framesCount: frames.count,
                state: &state
            )
        }

        state.noProgressCount = 0

        let accepted = makeAutomaticAcceptedFrame(
            previousFrame: step.previousFrame,
            settled: step.settled,
            frames: frames,
            analysis: analysis
        )
        frames.append(accepted)
        diagnostics.acceptedFrameCount = frames.count

        await sendProgress(
            ProgressUpdate(
                phase: .autoCapturing,
                mode: .automatic,
                frames: frames.count,
                estimatedHeight: accepted.estimatedBottom,
                status: "Capturing automatically",
                allowManualSwitch: session.request.config.allowManualFallback
            ),
            session: session
        )

        if accepted.estimatedBottom >= session.request.config.maxHeightPx {
            return .completed(.maxHeightReached)
        }

        state.requestedDisplacement = clamp(
            Int(Double(max(analysis.estimate.absoluteDisplacement, 1)) * 1.05),
            min: 60,
            max: state.maximumUsefulDisplacement
        )
        return .continueLoop
    }

    private func automaticEstimate(
        previousFrame: ScrollCaptureFrame,
        settled: ScrollSettledFrame,
        requestedDisplacement: Int
    ) -> AutomaticEstimateResult {
        var stickyHeaderHeight = previousFrame.stickyHeaderHeight
        var estimate = displacementEstimator.estimate(
            previous: previousFrame.preparedFrame,
            current: settled.preparedFrame,
            options: .automatic(
                expectedDisplacement: requestedDisplacement,
                stickyHeaderHeight: stickyHeaderHeight,
                unstableBands: settled.unstableBands
            )
        )

        if !estimate.isMeaningful && stickyHeaderHeight == 0 {
            let provisionalStickyHeader = ScrollCaptureHelpers.sharedTopRows(
                previous: previousFrame.preparedFrame,
                current: settled.preparedFrame
            )
            if provisionalStickyHeader >= 12 {
                stickyHeaderHeight = provisionalStickyHeader
                estimate = displacementEstimator.estimate(
                    previous: previousFrame.preparedFrame,
                    current: settled.preparedFrame,
                    options: .automatic(
                        expectedDisplacement: requestedDisplacement,
                        stickyHeaderHeight: stickyHeaderHeight,
                        unstableBands: settled.unstableBands
                    )
                )
            }
        }

        let detectedStickyHeader = ScrollCaptureHelpers.detectStickyHeaderHeight(
            frames: [previousFrame.preparedFrame, settled.preparedFrame]
        )
        return AutomaticEstimateResult(
            estimate: estimate,
            stickyHeaderHeight: max(stickyHeaderHeight, detectedStickyHeader)
        )
    }

    private func automaticFallbackTrigger(
        estimate: ScrollDisplacementEstimate,
        unstableBands: IndexSet,
        allowManualFallback: Bool,
        state: inout AutomaticLoopState
    ) -> String? {
        if estimate.confidence < ScrollCaptureThresholds.minimumAlignmentConfidence {
            state.lowConfidenceCount += 1
            if allowManualFallback && state.lowConfidenceCount >= 2 {
                return "low_alignment_confidence"
            }
        } else {
            state.lowConfidenceCount = 0
        }

        if unstableBands.count >= ScrollCaptureHelpers.bandCount / 2 {
            state.unstableBandCount += 1
            if allowManualFallback && state.unstableBandCount >= 2 {
                return "animated_content"
            }
        } else {
            state.unstableBandCount = 0
        }

        return nil
    }

    private func handleNoAutomaticProgress(
        step: AutomaticStep,
        framesCount: Int,
        state: inout AutomaticLoopState
    ) throws -> AutomaticStepDecision {
        let barUnchanged = automaticBarValueUnchanged(
            previous: step.previousBarValue,
            current: step.currentBarValue
        )

        if framesCount == 1 && barUnchanged {
            throw ScrollCaptureError.noScrollTarget
        }

        state.noProgressCount += 1
        state.requestedDisplacement = max(32, state.requestedDisplacement / 2)

        if state.noProgressCount >= 2 && barUnchanged {
            return .completed(.reachedBottom)
        }

        return .continueLoop
    }

    private func automaticBarValueUnchanged(
        previous: Double?,
        current: Double?
    ) -> Bool {
        if let previous, let current {
            return abs(current - previous) < 0.001 || current >= 0.995
        }
        return true
    }

    private func makeAutomaticAcceptedFrame(
        previousFrame: ScrollCaptureFrame,
        settled: ScrollSettledFrame,
        frames: [ScrollCaptureFrame],
        analysis: AutomaticEstimateResult
    ) -> ScrollCaptureFrame {
        let stickyHeaderHeight = max(
            analysis.stickyHeaderHeight,
            ScrollCaptureHelpers.detectStickyHeaderHeight(
                frames: frames.map(\.preparedFrame) + [settled.preparedFrame]
            )
        )

        return ScrollCaptureFrame(
            preparedFrame: settled.preparedFrame,
            placement: ScrollFramePlacement(
                originY: previousFrame.originY + analysis.estimate.absoluteDisplacement,
                displacementFromPrevious: analysis.estimate.absoluteDisplacement
            ),
            unstableBands: settled.unstableBands,
            stickyHeaderHeight: stickyHeaderHeight,
            displacementConfidence: analysis.estimate.confidence
        )
    }
}
