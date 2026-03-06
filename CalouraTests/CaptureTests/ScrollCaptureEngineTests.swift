@testable import Caloura
import CoreGraphics
import Foundation
import Testing

// swiftlint:disable file_length function_parameter_count large_tuple line_length

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
            region: surface.region,
            geometry: surface.geometry,
            config: .init(maxHeightPx: 2_000, scrollToTop: false),
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
            region: surface.region,
            geometry: surface.geometry,
            config: .init(maxHeightPx: 2_000, scrollToTop: false),
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
            region: surface.region,
            geometry: surface.geometry,
            config: .init(maxHeightPx: 2_000, scrollToTop: false),
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
            region: surface.region,
            geometry: surface.geometry,
            config: .init(maxHeightPx: 2_000, scrollToTop: false),
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
            region: surface.region,
            geometry: surface.geometry,
            config: .init(maxHeightPx: 2_000, scrollToTop: false, allowManualFallback: true),
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
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 2_000, scrollToTop: false, allowManualFallback: true),
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
            region: surface.region,
            geometry: surface.geometry,
            config: .init(maxHeightPx: 320, scrollToTop: false),
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

        let task = Task {
            await engine.capture(
                region: surface.region,
                geometry: surface.geometry,
                config: .init(maxHeightPx: 10_000, scrollToTop: false),
                captureFrame: { _ in surface.capture() },
                onProgress: { _ in }
            )
        }

        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()

        let result = await task.value
        guard case .cancelled = result else {
            Issue.record("Expected cancellation, got \(result)")
            return
        }
    }
}

// MARK: - Engine Test Doubles

private func makeEngine(
    surface: SyntheticScrollSurface,
    detector: FakeViewportDetector = FakeViewportDetector(mode: .automatic),
    settleDelayNanos: UInt64 = 0
) -> ScrollCaptureEngine {
    ScrollCaptureEngine(
        viewportDetector: detector,
        scrollDriver: FakeScrollDriver(surface: surface),
        settling: ImmediateSettler(delayNanos: settleDelayNanos),
        displacementEstimator: TestDisplacementEstimator(),
        stitcher: TestStitcher()
    )
}

private struct FakeViewportDetector: ScrollViewportDetecting, Sendable {
    enum Mode {
        case automatic
        case manualFallback
    }

    let mode: Mode

    func detectViewport(
        in region: CGRect,
        geometry: ScrollScreenGeometry
    ) -> ScrollViewportDetection {
        let rect = ScrollCaptureHelpers.pixelAlignedRect(
            region,
            scale: geometry.scale,
            within: geometry.localBounds
        )

        switch mode {
        case .automatic:
            return ScrollViewportDetection(
                detectedViewport: ScrollCaptureViewport(
                    captureRect: rect,
                    confidence: 0.91,
                    usedAutoDetectedViewport: true,
                    scrollElement: nil,
                    verticalScrollBar: nil
                ),
                fallbackRect: rect,
                isAmbiguous: false
            )
        case .manualFallback:
            return ScrollViewportDetection(
                detectedViewport: nil,
                fallbackRect: rect,
                isAmbiguous: false
            )
        }
    }
}

private final class FakeScrollDriver: ScrollDriving, @unchecked Sendable {
    private let surface: SyntheticScrollSurface

    init(surface: SyntheticScrollSurface) {
        self.surface = surface
    }

    func scroll(by pixels: Int) {
        surface.applyProgrammaticScroll(by: pixels)
    }

    func finishGesture() {}
}

private struct ImmediateSettler: ScrollSettling, Sendable {
    let delayNanos: UInt64

    func settle(
        region: CGRect,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        previousAcceptedFrame: ScrollCaptureHelpers.PreparedFrame?,
        expectedDisplacement: Int?,
        stickyHeaderHeight: Int,
        mode: ScrollCaptureMode,
        displacementEstimator: any ScrollDisplacementEstimating
    ) async throws -> ScrollSettledFrame? {
        if delayNanos > 0 {
            try await Task.sleep(nanoseconds: delayNanos)
        } else {
            await Task.yield()
        }

        let image = try await captureFrame(region)
        guard let prepared = ScrollCaptureHelpers.prepareFrame(image) else {
            return nil
        }

        if mode == .manual, let previousAcceptedFrame {
            let estimate = displacementEstimator.estimate(
                previous: previousAcceptedFrame,
                current: prepared,
                options: .manual(
                    expectedDisplacement: expectedDisplacement,
                    stickyHeaderHeight: stickyHeaderHeight,
                    unstableBands: []
                )
            )
            if !estimate.isMeaningful {
                return nil
            }
        }

        return ScrollSettledFrame(
            preparedFrame: prepared,
            unstableBands: [],
            stabilized: true,
            probeCount: 1
        )
    }
}

private struct TestDisplacementEstimator: ScrollDisplacementEstimating, Sendable {
    func estimate(
        previous: ScrollCaptureHelpers.PreparedFrame,
        current: ScrollCaptureHelpers.PreparedFrame,
        options: ScrollDisplacementOptions
    ) -> ScrollDisplacementEstimate {
        ScrollCaptureHelpers.estimateDisplacement(
            previous: previous,
            current: current,
            options: options
        )
    }
}

private struct TestStitcher: ScrollStitching, Sendable {
    func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult {
        try ScrollCaptureHelpers.stitch(frames: frames, maxCanvasHeight: maxCanvasHeight)
    }
}

// MARK: - Synthetic Surface

private final class SyntheticScrollSurface: @unchecked Sendable {
    let width: Int
    let viewportHeight: Int
    let contentHeight: Int
    let stickyHeaderHeight: Int
    let separatorEvery: Int
    let hasAnimatedBand: Bool
    let region: CGRect
    let geometry: ScrollScreenGeometry

    private let lock = NSLock()
    private var offset: Int = 0
    private var captureTick: Int = 0

    init(
        width: Int,
        viewportHeight: Int,
        contentHeight: Int,
        stickyHeaderHeight: Int = 0,
        separatorEvery: Int = 44,
        hasAnimatedBand: Bool = false
    ) {
        self.width = width
        self.viewportHeight = viewportHeight
        self.contentHeight = contentHeight
        self.stickyHeaderHeight = stickyHeaderHeight
        self.separatorEvery = separatorEvery
        self.hasAnimatedBand = hasAnimatedBand
        self.region = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        self.geometry = ScrollScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: width, height: viewportHeight),
            scale: 1,
            primaryScreenHeight: CGFloat(viewportHeight)
        )
    }

    var visibleContentHeight: Int {
        viewportHeight - stickyHeaderHeight
    }

    var maxOffset: Int {
        max(0, contentHeight - visibleContentHeight)
    }

    func applyProgrammaticScroll(by pixels: Int) {
        lock.lock()
        defer { lock.unlock() }
        offset = clampedOffset(offset + (-pixels))
    }

    func setOffset(_ newValue: Int) {
        lock.lock()
        defer { lock.unlock() }
        offset = clampedOffset(newValue)
    }

    func capture() -> CGImage {
        lock.lock()
        let currentOffset = offset
        captureTick += 1
        let tick = captureTick
        lock.unlock()
        return makeViewportImage(offset: currentOffset, tick: tick)
    }

    func expectedImage() -> CGImage {
        let totalHeight = stickyHeaderHeight + contentHeight
        return makeImage(height: totalHeight) { row, column, _ in
            pixel(row: row, column: column, contentOffset: 0)
        }
    }

    private func makeViewportImage(offset: Int, tick: Int) -> CGImage {
        makeImage(height: viewportHeight) { row, column, _ in
            pixel(row: row, column: column, contentOffset: offset, tick: tick)
        }
    }

    private func makeImage(
        height: Int,
        pixelForRow: (Int, Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                let (red, green, blue, alpha) = pixelForRow(row, column, row)
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
                pixels[offset + 3] = alpha
            }
        }

        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func pixel(
        row: Int,
        column: Int,
        contentOffset: Int,
        tick: Int = 0
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        if stickyHeaderHeight > 0 && row < stickyHeaderHeight {
            let shade = UInt8((row * 7 + column * 3) % 255)
            return (shade, UInt8(220 &- shade / 3), 210, 255)
        }

        let contentRow = row - stickyHeaderHeight + contentOffset
        let clampedRow = max(0, min(contentHeight - 1, contentRow))

        if separatorEvery > 0 && clampedRow % separatorEvery == 0 {
            return (36, 36, 36, 255)
        }
        if separatorEvery > 0 && clampedRow % separatorEvery == 1 {
            return (238, 238, 238, 255)
        }

        let animatedBand = stickyHeaderHeight + 54..<stickyHeaderHeight + 74
        if hasAnimatedBand && animatedBand.contains(row) {
            let animated = UInt8((tick * 17 + column * 5) % 255)
            return (animated, UInt8(255 &- animated / 2), 90, 255)
        }

        let red = UInt8(clampedRow & 0xFF)
        let green = UInt8((clampedRow >> 8) & 0xFF)
        let blue = UInt8((column * 7 + (clampedRow / 8)) & 0xFF)
        return (red, green, blue, 255)
    }

    private func clampedOffset(_ value: Int) -> Int {
        max(0, min(maxOffset, value))
    }
}

// MARK: - Assertions

private func requireSuccess(_ result: ScrollCaptureEngine.Result) throws -> ScrollCaptureOutput {
    switch result {
    case .success(let output):
        return output
    case .cancelled:
        throw CancellationError()
    case .failed(let error):
        throw error
    }
}

private func expectImagesEqual(_ lhs: CGImage, _ rhs: CGImage) throws {
    let left = try #require(ScrollCaptureHelpers.prepareFrame(lhs))
    let right = try #require(ScrollCaptureHelpers.prepareFrame(rhs))
    #expect(left.width == right.width)
    #expect(left.height == right.height)
    #expect(ScrollCaptureHelpers.pixelMatchRatio(left.bitmap, right.bitmap) > 0.999)
}

private func countHeaderMatches(_ image: CGImage, headerHeight: Int) -> Int {
    guard let prepared = ScrollCaptureHelpers.prepareFrame(image),
          headerHeight > 0,
          headerHeight < prepared.height else {
        return 0
    }

    let sampleStride = max(1, prepared.width / 32)
    func averageDifference(startRow: Int) -> Double {
        var total = 0
        var samples = 0
        for row in 0..<headerHeight {
            let headerOffset = row * prepared.width
            let candidateOffset = (startRow + row) * prepared.width
            for column in stride(from: 0, to: prepared.width, by: sampleStride) {
                total += abs(Int(prepared.grayscale[headerOffset + column]) - Int(prepared.grayscale[candidateOffset + column]))
                samples += 1
            }
        }
        return samples > 0 ? Double(total) / Double(samples) : .infinity
    }

    var matches = 0
    for startRow in stride(from: 0, through: prepared.height - headerHeight, by: max(1, headerHeight / 2))
    where averageDifference(startRow: startRow) < 1 {
        matches += 1
    }
    return matches
}

private actor ManualFinishController {
    private var didRequestFinish = false

    func requestFinishIfNeeded(control: ScrollCaptureControl) async {
        guard !didRequestFinish else { return }
        didRequestFinish = true
        await control.requestFinish()
    }
}

private actor CaptureTimeoutController {
    private(set) var didTimeout = false

    func recordTimeout() {
        didTimeout = true
    }
}
