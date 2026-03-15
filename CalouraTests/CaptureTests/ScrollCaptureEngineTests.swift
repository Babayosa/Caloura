@testable import Caloura
import CoreGraphics
import Foundation
import Testing

@Suite("ScrollCaptureEngine")
struct ScrollCaptureEngineTests {

    @Test("Automatic capture reaches the bottom of a long feed")
    func automaticCaptureReachesBottom() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 160,
            contentHeight: 520
        )
        let result = await makeEngine(surface: surface).capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 2_000, scrollToTop: false)
            ),
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        let output = try requireSuccess(result)
        #expect(output.mode == .automatic)
        #expect(output.terminationReason == .reachedBottom)
        #expect(output.image.height == 520)
        try expectImagesEqual(output.image, surface.expectedImage())
    }

    @Test("Separator rows do not produce seam lines")
    func separatorRowsRemainContinuous() async throws {
        let surface = SyntheticScrollSurface(
            width: 140,
            viewportHeight: 170,
            contentHeight: 640,
            separatorEvery: 36
        )
        let result = await makeEngine(surface: surface).capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 2_000, scrollToTop: false)
            ),
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        let output = try requireSuccess(result)
        try expectImagesEqual(output.image, surface.expectedImage())
    }

    @Test("Sticky header is included only once")
    func stickyHeaderAppearsOnce() async throws {
        let surface = SyntheticScrollSurface(
            width: 130,
            viewportHeight: 170,
            contentHeight: 460,
            stickyHeaderHeight: 24
        )
        let result = await makeEngine(surface: surface).capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 2_000, scrollToTop: false)
            ),
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        let output = try requireSuccess(result)
        #expect(abs(output.image.height - 484) <= 16)
        #expect(countHeaderMatches(output.image, headerHeight: 24) == 1)
    }

    @Test("No-scroll regions fail with noScrollTarget")
    func noScrollTargetFails() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 180,
            contentHeight: 120
        )
        let result = await makeEngine(surface: surface).capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 2_000, scrollToTop: false)
            ),
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        guard case .failed(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        #expect((error as? ScrollCaptureError) == .noScrollTarget)
    }

    @Test("Low-confidence viewport switches straight to manual mode")
    func lowConfidenceViewportFallsBackToManual() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 150,
            contentHeight: 420
        )
        let detector = FakeViewportDetector(mode: .manualFallback)
        let control = ScrollCaptureControl()
        let engine = makeEngine(surface: surface, detector: detector, settleDelayNanos: 2_000_000)

        Task {
            try? await Task.sleep(nanoseconds: 6_000_000)
            surface.setOffset(72)
            try? await Task.sleep(nanoseconds: 6_000_000)
            surface.setOffset(168)
            try? await Task.sleep(nanoseconds: 6_000_000)
            await control.requestFinish()
        }

        let result = await engine.capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(
                    maxHeightPx: 2_000,
                    scrollToTop: false,
                    allowManualFallback: true
                )
            ),
            control: control,
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        let output = try requireSuccess(result)
        #expect(output.mode == .manual)
        #expect(output.usedManualFallback)
        #expect(output.terminationReason == .manualFinished)
    }

    @Test("Manual mode accepts uneven user scrolls and stitches gap-free")
    func manualModeStitchesUnevenScrolls() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 150,
            contentHeight: 430
        )
        let detector = FakeViewportDetector(mode: .manualFallback)
        let control = ScrollCaptureControl()
        let engine = makeEngine(surface: surface, detector: detector, settleDelayNanos: 2_000_000)
        let finishController = ManualFinishController()
        let timeoutController = CaptureTimeoutController()

        let scrollTask = Task {
            for offset in stride(from: 20, through: surface.maxOffset, by: 20) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                surface.setOffset(offset)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            surface.setOffset(surface.maxOffset)
            try? await Task.sleep(nanoseconds: 250_000_000)
            await finishController.requestFinishIfNeeded(control: control)
        }

        let captureTask = Task {
            await engine.capture(
                .init(
                    region: surface.region,
                    geometry: surface.geometry,
                    config: .init(
                        maxHeightPx: 2_000,
                        scrollToTop: false,
                        allowManualFallback: true
                    )
                ),
                control: control,
                captureFrame: { _ in surface.capture() },
                onProgress: { _ in }
            )
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await timeoutController.recordTimeout()
            captureTask.cancel()
        }

        let result = await captureTask.value
        timeoutTask.cancel()
        _ = await scrollTask.result

        #expect(await timeoutController.didTimeout == false)
        let output = try requireSuccess(result)
        try expectImagesEqual(output.image, surface.expectedImage())
    }

    @Test("Manual displacement refinement preserves exact near-bottom placement")
    func manualDisplacementRefinementPreservesExactNearBottomPlacement() throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 150,
            contentHeight: 430
        )

        surface.setOffset(surface.maxOffset - 20)
        let previous = try #require(ScrollCaptureHelpers.prepareFrame(surface.capture()))

        surface.setOffset(surface.maxOffset)
        let current = try #require(ScrollCaptureHelpers.prepareFrame(surface.capture()))

        let estimate = ScrollCaptureHelpers.estimateDisplacement(
            previous: previous,
            current: current,
            options: .manual(expectedDisplacement: 20, stickyHeaderHeight: 0, unstableBands: [])
        )

        #expect(estimate.displacement == 20)
        #expect(estimate.isMeaningful)
    }

    @Test("Max-height termination returns a partial image with explicit reason")
    func maxHeightTermination() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 160,
            contentHeight: 640
        )
        let result = await makeEngine(surface: surface).capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 320, scrollToTop: false)
            ),
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        let output = try requireSuccess(result)
        #expect(output.terminationReason == .maxHeightReached)
        #expect(output.image.height == 320)
    }

    @Test("Cancellation exits cleanly")
    func cancellationExitsCleanly() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 160,
            contentHeight: 4_000
        )
        let engine = makeEngine(surface: surface, settleDelayNanos: 10_000_000)
        let captureStarted = AsyncGate()
        let releaseCapture = AsyncGate()

        let task = Task {
            await engine.capture(
                .init(
                    region: surface.region,
                    geometry: surface.geometry,
                    config: .init(maxHeightPx: 10_000, scrollToTop: false)
                ),
                captureFrame: { _ in
                    await captureStarted.open()
                    await releaseCapture.wait()
                    try Task.checkCancellation()
                    return surface.capture()
                },
                onProgress: { _ in }
            )
        }

        await captureStarted.wait()
        task.cancel()
        await releaseCapture.open()

        let result = await task.value
        guard case .cancelled = result else {
            Issue.record("Expected cancellation, got \(result)")
            return
        }
    }

    @Test("No-scroll surface with minimal content terminates with noScrollTarget")
    func noScrollTargetWithMinimalContent_terminatesCorrectly() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 180,
            contentHeight: 160
        )
        let result = await makeEngine(surface: surface).capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 2_000, scrollToTop: false)
            ),
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        guard case .failed(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        #expect((error as? ScrollCaptureError) == .noScrollTarget)
    }

    @Test("Automatic capture with large content captures full content")
    func automaticCaptureWithLargeContent_capturesFullContent() async throws {
        let surface = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 160,
            contentHeight: 800
        )
        let result = await makeEngine(surface: surface).capture(
            .init(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 2_000, scrollToTop: false)
            ),
            captureFrame: { _ in surface.capture() },
            onProgress: { _ in }
        )

        let output = try requireSuccess(result)
        #expect(output.terminationReason == .reachedBottom)
        #expect(abs(output.image.height - 800) <= 16)
    }

    @Test("Sticky header detection requires three frames")
    func stickyHeaderDetection_requiresThreeFrames() throws {
        let surface = SyntheticScrollSurface(
            width: 130,
            viewportHeight: 170,
            contentHeight: 460,
            stickyHeaderHeight: 24
        )

        surface.setOffset(0)
        let frame1 = try #require(ScrollCaptureHelpers.prepareFrame(surface.capture()))

        surface.setOffset(80)
        let frame2 = try #require(ScrollCaptureHelpers.prepareFrame(surface.capture()))

        surface.setOffset(160)
        let frame3 = try #require(ScrollCaptureHelpers.prepareFrame(surface.capture()))

        let height = ScrollCaptureHelpers.detectStickyHeaderHeight(frames: [frame1, frame2, frame3])
        #expect(height == 24)
    }

    @Test("Sticky header detection returns zero for fewer than three frames")
    func stickyHeaderDetection_returnsZeroForTwoFrames() throws {
        let surface = SyntheticScrollSurface(
            width: 130,
            viewportHeight: 170,
            contentHeight: 460,
            stickyHeaderHeight: 24
        )

        surface.setOffset(0)
        let frame1 = try #require(ScrollCaptureHelpers.prepareFrame(surface.capture()))

        surface.setOffset(80)
        let frame2 = try #require(ScrollCaptureHelpers.prepareFrame(surface.capture()))

        let height = ScrollCaptureHelpers.detectStickyHeaderHeight(frames: [frame1, frame2])
        #expect(height == 0)
    }

    @Test("Displacement estimate returns zero for mismatched frame sizes")
    func displacementEstimate_returnsZeroForMismatchedFrameSizes() throws {
        let surface1 = SyntheticScrollSurface(
            width: 120,
            viewportHeight: 160,
            contentHeight: 300
        )
        let surface2 = SyntheticScrollSurface(
            width: 100,
            viewportHeight: 140,
            contentHeight: 300
        )

        let frame1 = try #require(ScrollCaptureHelpers.prepareFrame(surface1.capture()))
        let frame2 = try #require(ScrollCaptureHelpers.prepareFrame(surface2.capture()))

        let estimate = ScrollCaptureHelpers.estimateDisplacement(
            previous: frame1,
            current: frame2,
            options: .automatic(expectedDisplacement: nil, stickyHeaderHeight: 0, unstableBands: [])
        )
        #expect(estimate.displacement == 0)
        #expect(estimate.confidence == 0)
    }
}
