import Foundation

extension ScrollCaptureEngine {
    func runManualCapture(
        frames: inout [ScrollCaptureFrame],
        viewport: ScrollCaptureViewport,
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> ScrollTerminationReason {
        var expectedDisplacement = frames.last?.placement.displacementFromPrevious

        while true {
            try Task.checkCancellation()

            if try await appendFinalManualFrameIfRequested(
                frames: &frames,
                viewport: viewport,
                expectedDisplacement: expectedDisplacement,
                session: session,
                diagnostics: &diagnostics
            ) {
                return .manualFinished
            }

            await sendProgress(
                ProgressUpdate(
                    phase: .manualCapturing,
                    mode: .manual,
                    frames: frames.count,
                    estimatedHeight: frames.last?.estimatedBottom ?? 0,
                    status: "Scroll smoothly in one direction, then press Return to finish",
                    allowManualSwitch: false
                ),
                session: session
            )

            guard let previousFrame = frames.last,
                  let settled = try await settling.settle(
                    request: ScrollSettleRequest(
                        region: viewport.captureRect,
                        previousAcceptedFrame: previousFrame.preparedFrame,
                        expectedDisplacement: expectedDisplacement,
                        stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                        mode: .manual
                    ),
                    captureFrame: session.captureFrame,
                    displacementEstimator: displacementEstimator
                  ),
                  let accepted = makeManualAcceptedFrame(
                    previousFrame: previousFrame,
                    settled: settled,
                    frames: frames,
                    expectedDisplacement: expectedDisplacement
                  ) else {
                continue
            }

            frames.append(accepted.frame)
            expectedDisplacement = accepted.displacement
            diagnostics.acceptedFrameCount = frames.count
            diagnostics.stepCount += 1

            if accepted.frame.estimatedBottom >= session.request.config.maxHeightPx {
                return .maxHeightReached
            }
        }
    }

    private func appendFinalManualFrameIfRequested(
        frames: inout [ScrollCaptureFrame],
        viewport: ScrollCaptureViewport,
        expectedDisplacement: Int?,
        session: Session,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> Bool {
        guard await session.control.isFinishRequested() else {
            return false
        }

        guard let previousFrame = frames.last,
              let settled = try await settling.settle(
                request: ScrollSettleRequest(
                    region: viewport.captureRect,
                    previousAcceptedFrame: previousFrame.preparedFrame,
                    expectedDisplacement: expectedDisplacement,
                    stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                    mode: .manual
                ),
                captureFrame: session.captureFrame,
                displacementEstimator: displacementEstimator
              ),
              let accepted = makeManualAcceptedFrame(
                previousFrame: previousFrame,
                settled: settled,
                frames: frames,
                expectedDisplacement: expectedDisplacement
              ) else {
            return true
        }

        frames.append(accepted.frame)
        diagnostics.acceptedFrameCount = frames.count
        diagnostics.stepCount += 1
        return true
    }

    private func makeManualAcceptedFrame(
        previousFrame: ScrollCaptureFrame,
        settled: ScrollSettledFrame,
        frames: [ScrollCaptureFrame],
        expectedDisplacement: Int?
    ) -> (frame: ScrollCaptureFrame, displacement: Int)? {
        let estimate = displacementEstimator.estimate(
            previous: previousFrame.preparedFrame,
            current: settled.preparedFrame,
            options: .manual(
                expectedDisplacement: expectedDisplacement,
                stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                unstableBands: settled.unstableBands
            )
        )

        guard estimate.isMeaningful else {
            return nil
        }

        let stickyHeaderHeight = max(
            previousFrame.stickyHeaderHeight,
            ScrollCaptureHelpers.detectStickyHeaderHeight(
                frames: frames.map(\.preparedFrame) + [settled.preparedFrame]
            )
        )

        let accepted = ScrollCaptureFrame(
            preparedFrame: settled.preparedFrame,
            placement: ScrollFramePlacement(
                originY: previousFrame.originY + estimate.absoluteDisplacement,
                displacementFromPrevious: estimate.absoluteDisplacement
            ),
            unstableBands: settled.unstableBands,
            stickyHeaderHeight: stickyHeaderHeight,
            displacementConfidence: estimate.confidence
        )
        return (accepted, estimate.absoluteDisplacement)
    }
}
