@testable import Caloura
import CoreGraphics
import Foundation
import Testing

func makeEngine(
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

struct FakeViewportDetector: ScrollViewportDetecting, Sendable {
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

final class FakeScrollDriver: ScrollDriving, @unchecked Sendable {
    private let surface: SyntheticScrollSurface

    init(surface: SyntheticScrollSurface) {
        self.surface = surface
    }

    func scroll(by pixels: Int) {
        surface.applyProgrammaticScroll(by: pixels)
    }

    func finishGesture() {}
}

struct ImmediateSettler: ScrollSettling, Sendable {
    let delayNanos: UInt64

    func settle(
        request: ScrollSettleRequest,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        displacementEstimator: any ScrollDisplacementEstimating
    ) async throws -> ScrollSettledFrame? {
        if delayNanos > 0 {
            try await Task.sleep(nanoseconds: delayNanos)
        } else {
            await Task.yield()
        }

        let image = try await captureFrame(request.region)
        guard let prepared = ScrollCaptureHelpers.prepareFrame(image) else {
            return nil
        }

        if request.mode == .manual,
           let previousAcceptedFrame = request.previousAcceptedFrame {
            let estimate = displacementEstimator.estimate(
                previous: previousAcceptedFrame,
                current: prepared,
                options: .manual(
                    expectedDisplacement: request.expectedDisplacement,
                    stickyHeaderHeight: request.stickyHeaderHeight,
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

struct TestDisplacementEstimator: ScrollDisplacementEstimating, Sendable {
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

struct TestStitcher: ScrollStitching, Sendable {
    func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult {
        try ScrollCaptureHelpers.stitch(frames: frames, maxCanvasHeight: maxCanvasHeight)
    }
}

struct SyntheticPixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

final class SyntheticScrollSurface: @unchecked Sendable {
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
        pixelForRow: (Int, Int, Int) -> SyntheticPixel
    ) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            for column in 0..<width {
                let pixelOffset = row * bytesPerRow + column * 4
                let pixel = pixelForRow(row, column, row)
                pixels[pixelOffset] = pixel.red
                pixels[pixelOffset + 1] = pixel.green
                pixels[pixelOffset + 2] = pixel.blue
                pixels[pixelOffset + 3] = pixel.alpha
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
    ) -> SyntheticPixel {
        if stickyHeaderHeight > 0 && row < stickyHeaderHeight {
            let shade = UInt8((row * 7 + column * 3) % 255)
            return SyntheticPixel(
                red: shade,
                green: UInt8(220 &- shade / 3),
                blue: 210,
                alpha: 255
            )
        }

        let contentRow = row - stickyHeaderHeight + contentOffset
        let clampedRow = max(0, min(contentHeight - 1, contentRow))

        if separatorEvery > 0 && clampedRow % separatorEvery == 0 {
            return SyntheticPixel(red: 36, green: 36, blue: 36, alpha: 255)
        }
        if separatorEvery > 0 && clampedRow % separatorEvery == 1 {
            return SyntheticPixel(red: 238, green: 238, blue: 238, alpha: 255)
        }

        let animatedBand = stickyHeaderHeight + 54..<stickyHeaderHeight + 74
        if hasAnimatedBand && animatedBand.contains(row) {
            let animated = UInt8((tick * 17 + column * 5) % 255)
            return SyntheticPixel(
                red: animated,
                green: UInt8(255 &- animated / 2),
                blue: 90,
                alpha: 255
            )
        }

        return SyntheticPixel(
            red: UInt8(clampedRow & 0xFF),
            green: UInt8((clampedRow >> 8) & 0xFF),
            blue: UInt8((column * 7 + (clampedRow / 8)) & 0xFF),
            alpha: 255
        )
    }

    private func clampedOffset(_ value: Int) -> Int {
        max(0, min(maxOffset, value))
    }
}

func requireSuccess(_ result: ScrollCaptureEngine.Result) throws -> ScrollCaptureOutput {
    switch result {
    case .success(let output):
        return output
    case .cancelled:
        throw CancellationError()
    case .failed(let error):
        throw error
    }
}

func expectImagesEqual(_ lhs: CGImage, _ rhs: CGImage) throws {
    let left = try #require(ScrollCaptureHelpers.prepareFrame(lhs))
    let right = try #require(ScrollCaptureHelpers.prepareFrame(rhs))
    #expect(left.width == right.width)
    #expect(left.height == right.height)
    #expect(ScrollCaptureHelpers.pixelMatchRatio(left.bitmap, right.bitmap) > 0.999)
}

func countHeaderMatches(_ image: CGImage, headerHeight: Int) -> Int {
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
                total += abs(
                    Int(prepared.grayscale[headerOffset + column]) -
                    Int(prepared.grayscale[candidateOffset + column])
                )
                samples += 1
            }
        }
        return samples > 0 ? Double(total) / Double(samples) : .infinity
    }

    var matches = 0
    for startRow in stride(
        from: 0,
        through: prepared.height - headerHeight,
        by: max(1, headerHeight / 2)
    ) where averageDifference(startRow: startRow) < 1 {
        matches += 1
    }
    return matches
}

actor ManualFinishController {
    private var didRequestFinish = false

    func requestFinishIfNeeded(control: ScrollCaptureControl) async {
        guard !didRequestFinish else { return }
        didRequestFinish = true
        await control.requestFinish()
    }
}

actor CaptureTimeoutController {
    private(set) var didTimeout = false

    func recordTimeout() {
        didTimeout = true
    }
}
