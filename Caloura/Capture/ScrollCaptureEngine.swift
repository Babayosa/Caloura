import AppKit
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.caloura.app", category: "ScrollCapture")
// swiftlint:disable file_length type_body_length function_body_length function_parameter_count cyclomatic_complexity line_length

enum ScrollCapturePreferredDirection: String, Sendable {
    case auto
    case down
    case up
}

enum ScrollCaptureModeBias: String, Sendable {
    case automaticPreferred
    case manualPreferred
}

enum ScrollCaptureMode: String, Sendable {
    case automatic
    case manual
}

enum ScrollCapturePhase: String, Sendable {
    case preparing = "Preparing"
    case detectingViewport = "Detecting viewport"
    case calibrating = "Calibrating"
    case autoCapturing = "Auto capturing"
    case manualCapturing = "Manual capture"
    case finalizing = "Finalizing"
    case completed = "Completed"
    case failed = "Failed"
}

enum ScrollTerminationReason: String, Sendable {
    case reachedBottom
    case maxHeightReached
    case manualFinished
}

struct ScrollCaptureProgress: Sendable {
    let phase: ScrollCapturePhase
    let mode: ScrollCaptureMode
    let frameCount: Int
    let estimatedHeight: Int
    let status: String
    let canSwitchToManual: Bool
    let canFinishManual: Bool
}

struct ScrollCaptureDiagnostics: Sendable {
    var targetAppName: String?
    var mode: ScrollCaptureMode = .automatic
    var viewportConfidence: Double = 0
    var stepCount: Int = 0
    var fallbackTrigger: String?
    var terminationReason: ScrollTerminationReason?
    var seamRepairCount: Int = 0
    var usedAutoDetectedViewport: Bool = false
    var acceptedFrameCount: Int = 0
}

struct ScrollCaptureOutput: @unchecked Sendable {
    let image: CGImage
    let mode: ScrollCaptureMode
    let terminationReason: ScrollTerminationReason
    let usedManualFallback: Bool
    let diagnostics: ScrollCaptureDiagnostics
}

actor ScrollCaptureControl {
    private var manualRequested = false
    private var finishRequested = false

    func requestManual() {
        manualRequested = true
    }

    func consumeManualRequest() -> Bool {
        let requested = manualRequested
        manualRequested = false
        return requested
    }

    func requestFinish() {
        finishRequested = true
    }

    func isFinishRequested() -> Bool {
        finishRequested
    }
}

struct ScrollDisplacementOptions {
    let expectedDisplacement: Int?
    let allowedDelta: Int
    let stickyHeaderHeight: Int
    let bottomExclusion: Int
    let unstableBands: IndexSet
    let allowNegativeDisplacement: Bool

    static func automatic(
        expectedDisplacement: Int?,
        stickyHeaderHeight: Int,
        unstableBands: IndexSet
    ) -> Self {
        Self(
            expectedDisplacement: expectedDisplacement,
            allowedDelta: 120,
            stickyHeaderHeight: stickyHeaderHeight,
            bottomExclusion: 24,
            unstableBands: unstableBands,
            allowNegativeDisplacement: false
        )
    }

    static func calibration(expectedDisplacement: Int) -> Self {
        Self(
            expectedDisplacement: expectedDisplacement,
            allowedDelta: 140,
            stickyHeaderHeight: 0,
            bottomExclusion: 24,
            unstableBands: [],
            allowNegativeDisplacement: true
        )
    }

    static func manual(
        expectedDisplacement: Int?,
        stickyHeaderHeight: Int,
        unstableBands: IndexSet
    ) -> Self {
        Self(
            expectedDisplacement: expectedDisplacement,
            allowedDelta: 200,
            stickyHeaderHeight: stickyHeaderHeight,
            bottomExclusion: 24,
            unstableBands: unstableBands,
            allowNegativeDisplacement: false
        )
    }

    static func probeStability() -> Self {
        Self(
            expectedDisplacement: 0,
            allowedDelta: 16,
            stickyHeaderHeight: 0,
            bottomExclusion: 12,
            unstableBands: [],
            allowNegativeDisplacement: true
        )
    }
}

struct ScrollDisplacementEstimate {
    enum Method: String {
        case bandMatch
        case vision
        case none
    }

    let displacement: Int
    let confidence: Double
    let winnerMargin: Double
    let meanError: Double
    let method: Method

    var absoluteDisplacement: Int { abs(displacement) }
    var isMeaningful: Bool {
        absoluteDisplacement >= 12 && confidence >= 0.35
    }
}

struct ScrollFramePlacement {
    let originY: Int
    let displacementFromPrevious: Int
}

struct ScrollCaptureFrame {
    let preparedFrame: ScrollCaptureHelpers.PreparedFrame
    let placement: ScrollFramePlacement
    let unstableBands: IndexSet
    let stickyHeaderHeight: Int
    let displacementConfidence: Double

    var image: CGImage { preparedFrame.image }
    var width: Int { preparedFrame.width }
    var height: Int { preparedFrame.height }
    var originY: Int { placement.originY }
    var estimatedBottom: Int { placement.originY + preparedFrame.height }
}

struct ScrollStitchResult {
    let image: CGImage
    let seamRepairCount: Int
}

struct ScrollSettledFrame {
    let preparedFrame: ScrollCaptureHelpers.PreparedFrame
    let unstableBands: IndexSet
    let stabilized: Bool
    let probeCount: Int
}

struct ScrollScreenGeometry {
    let frame: CGRect
    let scale: CGFloat
    let primaryScreenHeight: CGFloat

    var localBounds: CGRect {
        CGRect(origin: .zero, size: frame.size)
    }
}

struct ScrollCaptureViewport {
    let captureRect: CGRect
    let confidence: Double
    let usedAutoDetectedViewport: Bool
    let scrollElement: AXUIElement?
    let verticalScrollBar: AXUIElement?
}

struct ScrollViewportDetection {
    let detectedViewport: ScrollCaptureViewport?
    let fallbackRect: CGRect
    let isAmbiguous: Bool
}

protocol ScrollViewportDetecting {
    func detectViewport(
        in region: CGRect,
        geometry: ScrollScreenGeometry
    ) -> ScrollViewportDetection
}

protocol ScrollDriving: AnyObject {
    func scroll(by pixels: Int)
    func finishGesture()
}

protocol ScrollSettling {
    func settle(
        region: CGRect,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        previousAcceptedFrame: ScrollCaptureHelpers.PreparedFrame?,
        expectedDisplacement: Int?,
        stickyHeaderHeight: Int,
        mode: ScrollCaptureMode,
        displacementEstimator: any ScrollDisplacementEstimating
    ) async throws -> ScrollSettledFrame?
}

protocol ScrollDisplacementEstimating {
    func estimate(
        previous: ScrollCaptureHelpers.PreparedFrame,
        current: ScrollCaptureHelpers.PreparedFrame,
        options: ScrollDisplacementOptions
    ) -> ScrollDisplacementEstimate
}

protocol ScrollStitching {
    func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult
}

enum ScrollCaptureError: LocalizedError, Sendable {
    case noScrollableViewport
    case noScrollTarget
    case unstableScrolling
    case framePreparationFailed
    case noFramesCaptured
    case canvasCreationFailed

    var errorDescription: String? {
        switch self {
        case .noScrollableViewport:
            return "No scrollable viewport found in the selected area."
        case .noScrollTarget:
            return "The selected area did not scroll."
        case .unstableScrolling:
            return "Could not stabilize scrolling."
        case .framePreparationFailed:
            return "Could not prepare captured frame data."
        case .noFramesCaptured:
            return "No frames were captured."
        case .canvasCreationFailed:
            return "Failed to create the stitched image."
        }
    }
}

// swiftlint:disable file_length
actor ScrollCaptureEngine {

    struct Config: Sendable {
        let maxHeightPx: Int
        let scrollToTop: Bool
        let allowManualFallback: Bool
        let preferredDirection: ScrollCapturePreferredDirection
        let modeBias: ScrollCaptureModeBias

        init(
            maxHeightPx: Int = 20_000,
            scrollToTop: Bool = false,
            allowManualFallback: Bool = true,
            preferredDirection: ScrollCapturePreferredDirection = .auto,
            modeBias: ScrollCaptureModeBias = .automaticPreferred
        ) {
            self.maxHeightPx = maxHeightPx
            self.scrollToTop = scrollToTop
            self.allowManualFallback = allowManualFallback
            self.preferredDirection = preferredDirection
            self.modeBias = modeBias
        }
    }

    enum Result: @unchecked Sendable {
        case success(ScrollCaptureOutput)
        case cancelled
        case failed(Error)
    }

    private let viewportDetector: any ScrollViewportDetecting
    private let scrollDriver: any ScrollDriving
    private let settling: any ScrollSettling
    private let displacementEstimator: any ScrollDisplacementEstimating
    private let stitcher: any ScrollStitching

    init(
        viewportDetector: any ScrollViewportDetecting = DefaultViewportDetector(),
        scrollDriver: any ScrollDriving = DefaultScrollDriver(),
        settling: any ScrollSettling = DefaultScrollSettling(),
        displacementEstimator: any ScrollDisplacementEstimating = DefaultScrollDisplacementEstimator(),
        stitcher: any ScrollStitching = DefaultScrollStitcher()
    ) {
        self.viewportDetector = viewportDetector
        self.scrollDriver = scrollDriver
        self.settling = settling
        self.displacementEstimator = displacementEstimator
        self.stitcher = stitcher
    }

    func capture(
        region: CGRect,
        screen: NSScreen,
        config: Config,
        control: ScrollCaptureControl = ScrollCaptureControl(),
        captureFrame: @escaping @Sendable (CGRect, NSScreen) async throws -> CGImage,
        onProgress: @MainActor @Sendable (ScrollCaptureProgress) -> Void
    ) async -> Result {
        let geometry = await MainActor.run { () -> ScrollScreenGeometry in
            ScrollScreenGeometry(
                frame: screen.frame,
                scale: screen.backingScaleFactor,
                primaryScreenHeight: NSScreen.screens.first?.frame.height ?? screen.frame.height
            )
        }

        let appName = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }

        return await capture(
            region: region,
            geometry: geometry,
            config: config,
            control: control,
            targetAppName: appName,
            captureFrame: { rect in
                try await captureFrame(rect, screen)
            },
            onProgress: onProgress
        )
    }

    func capture(
        region: CGRect,
        geometry: ScrollScreenGeometry,
        config: Config,
        control: ScrollCaptureControl = ScrollCaptureControl(),
        targetAppName: String? = nil,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        onProgress: @MainActor @Sendable (ScrollCaptureProgress) -> Void
    ) async -> Result {
        var diagnostics = ScrollCaptureDiagnostics(targetAppName: targetAppName)
        await sendProgress(
            phase: .preparing,
            mode: config.modeBias == .manualPreferred ? .manual : .automatic,
            frames: 0,
            estimatedHeight: 0,
            status: "Preparing scroll capture",
            allowManualSwitch: config.allowManualFallback,
            onProgress: onProgress
        )

        do {
            let detection = viewportDetector.detectViewport(in: region, geometry: geometry)
            let lockedViewport = try resolveViewport(
                detection: detection,
                geometry: geometry,
                config: config,
                diagnostics: &diagnostics
            )

            var mode: ScrollCaptureMode = config.modeBias == .manualPreferred ? .manual : .automatic
            if detection.detectedViewport == nil || detection.isAmbiguous {
                mode = .manual
            }

            diagnostics.mode = mode

            if config.scrollToTop && mode == .automatic {
                await sendProgress(
                    phase: .preparing,
                    mode: mode,
                    frames: 0,
                    estimatedHeight: 0,
                    status: "Scrolling to top",
                    allowManualSwitch: config.allowManualFallback,
                    onProgress: onProgress
                )
                try await scrollToTopIfNeeded(scrollBar: lockedViewport.verticalScrollBar)
            }

            guard let firstPrepared = try await prepareCapturedFrame(
                rect: lockedViewport.captureRect,
                captureFrame: captureFrame
            ) else {
                throw ScrollCaptureError.framePreparationFailed
            }

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
                phase: mode == .automatic ? .detectingViewport : .manualCapturing,
                mode: mode,
                frames: frames.count,
                estimatedHeight: frames.last?.estimatedBottom ?? 0,
                status: mode == .automatic ? "Viewport locked" : "Manual capture ready",
                allowManualSwitch: config.allowManualFallback,
                onProgress: onProgress
            )

            var scrollDirection = initialScrollDirection(for: config)
            var usedManualFallback = mode == .manual

            if mode == .automatic {
                let calibration = try await calibrateDirection(
                    viewport: lockedViewport,
                    geometry: geometry,
                    baselineFrame: firstPrepared,
                    currentDirection: scrollDirection,
                    captureFrame: captureFrame,
                    onProgress: onProgress,
                    diagnostics: &diagnostics,
                    config: config
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

            let terminationReason: ScrollTerminationReason
            if mode == .automatic {
                let automaticResult = try await runAutomaticCapture(
                    frames: &frames,
                    viewport: lockedViewport,
                    geometry: geometry,
                    config: config,
                    control: control,
                    scrollDirection: scrollDirection,
                    captureFrame: captureFrame,
                    onProgress: onProgress,
                    diagnostics: &diagnostics
                )

                switch automaticResult {
                case .completed(let reason):
                    terminationReason = reason
                case .fallbackToManual(let trigger):
                    diagnostics.fallbackTrigger = trigger
                    diagnostics.mode = .manual
                    usedManualFallback = true
                    terminationReason = try await runManualCapture(
                        frames: &frames,
                        viewport: lockedViewport,
                        config: config,
                        control: control,
                        captureFrame: captureFrame,
                        onProgress: onProgress,
                        diagnostics: &diagnostics
                    )
                }
            } else {
                terminationReason = try await runManualCapture(
                    frames: &frames,
                    viewport: lockedViewport,
                    config: config,
                    control: control,
                    captureFrame: captureFrame,
                    onProgress: onProgress,
                    diagnostics: &diagnostics
                )
            }

            scrollDriver.finishGesture()

            guard let firstFrame = frames.first else {
                throw ScrollCaptureError.noFramesCaptured
            }

            diagnostics.acceptedFrameCount = frames.count
            diagnostics.terminationReason = terminationReason

            await sendProgress(
                phase: .finalizing,
                mode: diagnostics.mode,
                frames: frames.count,
                estimatedHeight: frames.last?.estimatedBottom ?? firstFrame.height,
                status: "Finalizing capture",
                allowManualSwitch: false,
                onProgress: onProgress
            )

            let finalImage: CGImage
            if frames.count == 1 {
                finalImage = firstFrame.image
            } else {
                let stitched = try stitcher.stitch(frames: frames, maxCanvasHeight: config.maxHeightPx)
                diagnostics.seamRepairCount = stitched.seamRepairCount
                finalImage = stitched.image
            }

            await sendProgress(
                phase: .completed,
                mode: diagnostics.mode,
                frames: frames.count,
                estimatedHeight: min(config.maxHeightPx, finalImage.height),
                status: "Scroll capture complete",
                allowManualSwitch: false,
                onProgress: onProgress
            )

            logger.info(
                "Scroll capture complete mode=\(diagnostics.mode.rawValue, privacy: .public) frames=\(frames.count, privacy: .public) height=\(finalImage.height, privacy: .public) viewportConfidence=\(diagnostics.viewportConfidence, format: .fixed(precision: 2)) fallback=\(diagnostics.fallbackTrigger ?? "none", privacy: .public) reason=\(terminationReason.rawValue, privacy: .public)"
            )

            return .success(
                ScrollCaptureOutput(
                    image: finalImage,
                    mode: diagnostics.mode,
                    terminationReason: terminationReason,
                    usedManualFallback: usedManualFallback,
                    diagnostics: diagnostics
                )
            )
        } catch is CancellationError {
            scrollDriver.finishGesture()
            return .cancelled
        } catch {
            scrollDriver.finishGesture()
            await sendProgress(
                phase: .failed,
                mode: diagnostics.mode,
                frames: diagnostics.acceptedFrameCount,
                estimatedHeight: 0,
                status: error.localizedDescription,
                allowManualSwitch: false,
                onProgress: onProgress
            )
            return .failed(error)
        }
    }

    // MARK: - Session Flow

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
        return ScrollCaptureHelpers.prepareFrame(image)
    }

    private func calibrateDirection(
        viewport: ScrollCaptureViewport,
        geometry: ScrollScreenGeometry,
        baselineFrame: ScrollCaptureHelpers.PreparedFrame,
        currentDirection: Int,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        onProgress: @MainActor @Sendable (ScrollCaptureProgress) -> Void,
        diagnostics: inout ScrollCaptureDiagnostics,
        config: Config
    ) async throws -> (baselineFrame: ScrollCaptureHelpers.PreparedFrame, scrollDirection: Int) {
        let maximumUsefulDisplacement = max(40, baselineFrame.height - 32)
        let trialDisplacement = min(
            maximumUsefulDisplacement,
            max(40, Int(Double(baselineFrame.height) * 0.25))
        )
        let trialPixels = currentDirection * trialDisplacement

        await sendProgress(
            phase: .calibrating,
            mode: .automatic,
            frames: 1,
            estimatedHeight: baselineFrame.height,
            status: "Calibrating scroll direction",
            allowManualSwitch: config.allowManualFallback,
            onProgress: onProgress
        )

        scrollDriver.scroll(by: trialPixels)
        let forwardProbe = try await settling.settle(
            region: viewport.captureRect,
            captureFrame: captureFrame,
            previousAcceptedFrame: baselineFrame,
            expectedDisplacement: trialDisplacement,
            stickyHeaderHeight: 0,
            mode: .automatic,
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
            region: viewport.captureRect,
            captureFrame: captureFrame,
            previousAcceptedFrame: forwardProbe?.preparedFrame ?? baselineFrame,
            expectedDisplacement: trialDisplacement,
            stickyHeaderHeight: 0,
            mode: .automatic,
            displacementEstimator: displacementEstimator
        )?.preparedFrame ?? baselineFrame

        let finalDirection: Int
        if let forwardEstimate,
           forwardEstimate.confidence >= 0.35,
           forwardEstimate.displacement <= -12 {
            finalDirection = -currentDirection
        } else {
            finalDirection = currentDirection
        }

        diagnostics.stepCount += 1
        _ = geometry
        return (returnedBaseline, finalDirection)
    }

    private enum AutomaticCaptureResult {
        case completed(ScrollTerminationReason)
        case fallbackToManual(String)
    }

    private func runAutomaticCapture(
        frames: inout [ScrollCaptureFrame],
        viewport: ScrollCaptureViewport,
        geometry: ScrollScreenGeometry,
        config: Config,
        control: ScrollCaptureControl,
        scrollDirection: Int,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        onProgress: @MainActor @Sendable (ScrollCaptureProgress) -> Void,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> AutomaticCaptureResult {
        let maximumUsefulDisplacement = max(
            40,
            frames[0].height - max(24, frames[0].stickyHeaderHeight + 8)
        )
        var requestedDisplacement = clamp(
            Int(Double(frames[0].height) * 0.72),
            min: 60,
            max: maximumUsefulDisplacement
        )
        var noProgressCount = 0
        var lowConfidenceCount = 0
        var unstableBandCount = 0
        let maxLoops = 300

        for _ in 0..<maxLoops {
            try Task.checkCancellation()

            let manualRequested = config.allowManualFallback
                ? await control.consumeManualRequest()
                : false
            if manualRequested {
                return .fallbackToManual("user_switch")
            }

            let previousFrame = frames[frames.count - 1]
            let previousBarValue = viewport.verticalScrollBar.map(axScrollValue)
            scrollDriver.scroll(by: scrollDirection * requestedDisplacement)

            var settled = try await settling.settle(
                region: viewport.captureRect,
                captureFrame: captureFrame,
                previousAcceptedFrame: previousFrame.preparedFrame,
                expectedDisplacement: requestedDisplacement,
                stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                mode: .automatic,
                displacementEstimator: displacementEstimator
            )

            if settled?.stabilized == false {
                settled = try await settling.settle(
                    region: viewport.captureRect,
                    captureFrame: captureFrame,
                    previousAcceptedFrame: previousFrame.preparedFrame,
                    expectedDisplacement: requestedDisplacement,
                    stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                    mode: .automatic,
                    displacementEstimator: displacementEstimator
                )
            }

            guard let settled else {
                if config.allowManualFallback {
                    return .fallbackToManual("no_settled_frame")
                }
                throw ScrollCaptureError.unstableScrolling
            }

            if !settled.stabilized {
                if config.allowManualFallback {
                    return .fallbackToManual("unstable_scroll")
                }
                throw ScrollCaptureError.unstableScrolling
            }

            var effectiveStickyHeaderHeight = previousFrame.stickyHeaderHeight
            var estimate = displacementEstimator.estimate(
                previous: previousFrame.preparedFrame,
                current: settled.preparedFrame,
                options: .automatic(
                    expectedDisplacement: requestedDisplacement,
                    stickyHeaderHeight: effectiveStickyHeaderHeight,
                    unstableBands: settled.unstableBands
                )
            )

            if !estimate.isMeaningful && effectiveStickyHeaderHeight == 0 {
                let provisionalStickyHeader = ScrollCaptureHelpers.sharedTopRows(
                    previous: previousFrame.preparedFrame,
                    current: settled.preparedFrame
                )
                if provisionalStickyHeader >= 12 {
                    effectiveStickyHeaderHeight = provisionalStickyHeader
                    estimate = displacementEstimator.estimate(
                        previous: previousFrame.preparedFrame,
                        current: settled.preparedFrame,
                        options: .automatic(
                            expectedDisplacement: requestedDisplacement,
                            stickyHeaderHeight: effectiveStickyHeaderHeight,
                            unstableBands: settled.unstableBands
                        )
                    )
                }
            }

            diagnostics.stepCount += 1

            if estimate.confidence < 0.35 {
                lowConfidenceCount += 1
                if config.allowManualFallback && lowConfidenceCount >= 2 {
                    return .fallbackToManual("low_alignment_confidence")
                }
            } else {
                lowConfidenceCount = 0
            }

            if settled.unstableBands.count >= ScrollCaptureHelpers.bandCount / 2 {
                unstableBandCount += 1
                if config.allowManualFallback && unstableBandCount >= 2 {
                    return .fallbackToManual("animated_content")
                }
            } else {
                unstableBandCount = 0
            }

            let currentBarValue = viewport.verticalScrollBar.map(axScrollValue)

            if !estimate.isMeaningful {
                let barUnchanged: Bool
                if let previousBarValue, let currentBarValue {
                    barUnchanged = abs(currentBarValue - previousBarValue) < 0.001 || currentBarValue >= 0.995
                } else {
                    barUnchanged = true
                }

                if frames.count == 1 && barUnchanged {
                    throw ScrollCaptureError.noScrollTarget
                }

                noProgressCount += 1
                requestedDisplacement = max(32, requestedDisplacement / 2)

                if noProgressCount >= 2 && barUnchanged {
                    return .completed(.reachedBottom)
                }

                continue
            }

            noProgressCount = 0

            let actualDisplacement = estimate.absoluteDisplacement
            let stickyHeaderHeight = max(
                effectiveStickyHeaderHeight,
                ScrollCaptureHelpers.detectStickyHeaderHeight(
                    frames: frames.map(\.preparedFrame) + [settled.preparedFrame]
                )
            )

            let originY = previousFrame.originY + actualDisplacement
            let accepted = ScrollCaptureFrame(
                preparedFrame: settled.preparedFrame,
                placement: ScrollFramePlacement(
                    originY: originY,
                    displacementFromPrevious: actualDisplacement
                ),
                unstableBands: settled.unstableBands,
                stickyHeaderHeight: stickyHeaderHeight,
                displacementConfidence: estimate.confidence
            )
            frames.append(accepted)

            diagnostics.acceptedFrameCount = frames.count

            await sendProgress(
                phase: .autoCapturing,
                mode: .automatic,
                frames: frames.count,
                estimatedHeight: accepted.estimatedBottom,
                status: "Capturing automatically",
                allowManualSwitch: config.allowManualFallback,
                onProgress: onProgress
            )

            if accepted.estimatedBottom >= config.maxHeightPx {
                return .completed(.maxHeightReached)
            }

            requestedDisplacement = clamp(
                Int(Double(max(actualDisplacement, 1)) * 1.05),
                min: 60,
                max: maximumUsefulDisplacement
            )
        }

        return .completed(.maxHeightReached)
    }

    private func runManualCapture(
        frames: inout [ScrollCaptureFrame],
        viewport: ScrollCaptureViewport,
        config: Config,
        control: ScrollCaptureControl,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        onProgress: @MainActor @Sendable (ScrollCaptureProgress) -> Void,
        diagnostics: inout ScrollCaptureDiagnostics
    ) async throws -> ScrollTerminationReason {
        var expectedDisplacement = frames.last?.placement.displacementFromPrevious
        while true {
            try Task.checkCancellation()

            if await control.isFinishRequested() {
                return .manualFinished
            }

            await sendProgress(
                phase: .manualCapturing,
                mode: .manual,
                frames: frames.count,
                estimatedHeight: frames.last?.estimatedBottom ?? 0,
                status: "Scroll smoothly in one direction, then press Return to finish",
                allowManualSwitch: false,
                onProgress: onProgress
            )

            guard let previousFrame = frames.last else {
                throw ScrollCaptureError.noFramesCaptured
            }

            guard let settled = try await settling.settle(
                region: viewport.captureRect,
                captureFrame: captureFrame,
                previousAcceptedFrame: previousFrame.preparedFrame,
                expectedDisplacement: expectedDisplacement,
                stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                mode: .manual,
                displacementEstimator: displacementEstimator
            ) else {
                continue
            }

            let estimate = displacementEstimator.estimate(
                previous: previousFrame.preparedFrame,
                current: settled.preparedFrame,
                options: .manual(
                    expectedDisplacement: expectedDisplacement,
                    stickyHeaderHeight: previousFrame.stickyHeaderHeight,
                    unstableBands: settled.unstableBands
                )
            )

            if !estimate.isMeaningful {
                continue
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
            frames.append(accepted)
            expectedDisplacement = estimate.absoluteDisplacement
            diagnostics.acceptedFrameCount = frames.count
            diagnostics.stepCount += 1

            if accepted.estimatedBottom >= config.maxHeightPx {
                return .maxHeightReached
            }
        }
    }

    // MARK: - Progress

    private func sendProgress(
        phase: ScrollCapturePhase,
        mode: ScrollCaptureMode,
        frames: Int,
        estimatedHeight: Int,
        status: String,
        allowManualSwitch: Bool,
        onProgress: @MainActor @Sendable (ScrollCaptureProgress) -> Void
    ) async {
        await onProgress(
            ScrollCaptureProgress(
                phase: phase,
                mode: mode,
                frameCount: frames,
                estimatedHeight: estimatedHeight,
                status: status,
                canSwitchToManual: allowManualSwitch && mode == .automatic,
                canFinishManual: mode == .manual
            )
        )
    }

    // MARK: - AX Utilities

    private func axScrollValue(_ scrollBar: AXUIElement) -> Double {
        guard let value = axAttribute(scrollBar, kAXValueAttribute) as? NSNumber else {
            return 0
        }
        return value.doubleValue
    }

    private func axAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func scrollToTopIfNeeded(scrollBar: AXUIElement?) async throws {
        guard let scrollBar else {
            return
        }

        var attempts = 0
        while attempts < 120 && axScrollValue(scrollBar) > 0.005 {
            scrollDriver.scroll(by: 900)
            attempts += 1
            try await Task.sleep(nanoseconds: 18_000_000)
        }
        scrollDriver.finishGesture()
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    private func initialScrollDirection(for config: Config) -> Int {
        switch config.preferredDirection {
        case .up:
            return 1
        case .auto, .down:
            return -1
        }
    }
}

// MARK: - Default Implementations

private struct DefaultViewportDetector: ScrollViewportDetecting {
    private struct Candidate {
        let element: AXUIElement
        let frame: CGRect
        let role: String
        let verticalScrollBar: AXUIElement?
        let supportsValue: Bool
        let hitCount: Int
        let confidence: Double
    }

    func detectViewport(
        in region: CGRect,
        geometry: ScrollScreenGeometry
    ) -> ScrollViewportDetection {
        let fallbackRect = ScrollCaptureHelpers.pixelAlignedRect(
            region,
            scale: geometry.scale,
            within: geometry.localBounds
        )
        let systemWide = AXUIElementCreateSystemWide()
        let probeFractions: [CGFloat] = [0.2, 0.5, 0.8]
        var accumulators: [String: CandidateAccumulator] = [:]

        for yFraction in probeFractions {
            for xFraction in probeFractions {
                let localPoint = CGPoint(
                    x: region.minX + region.width * xFraction,
                    y: region.minY + region.height * yFraction
                )
                let globalX = geometry.frame.origin.x + localPoint.x
                let globalY = geometry.primaryScreenHeight - (geometry.frame.origin.y + localPoint.y)

                var elementRef: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(
                    systemWide,
                    Float(globalX),
                    Float(globalY),
                    &elementRef
                )
                guard result == .success, let elementRef else { continue }

                walkAncestors(from: elementRef, region: region, geometry: geometry) { candidate in
                    let key = candidate.identifier
                    var accumulator = accumulators[key] ?? CandidateAccumulator(
                        identifier: key,
                        element: candidate.element,
                        frame: candidate.frame,
                        role: candidate.role,
                        verticalScrollBar: candidate.verticalScrollBar,
                        supportsValue: candidate.supportsValue,
                        hitCount: 0
                    )
                    accumulator.hitCount += 1
                    accumulators[key] = accumulator
                }
            }
        }

        let candidates = accumulators.values
            .compactMap { accumulator in
                scoreCandidate(accumulator, region: region)
            }
            .sorted { lhs, rhs in
                lhs.confidence > rhs.confidence
            }

        guard let best = candidates.first else {
            return ScrollViewportDetection(
                detectedViewport: nil,
                fallbackRect: fallbackRect,
                isAmbiguous: false
            )
        }

        let ambiguous = candidates.count > 1
            && best.confidence >= 0.55
            && candidates[1].confidence >= 0.55
            && abs(best.confidence - candidates[1].confidence) < 0.08

        guard best.confidence >= 0.55, !ambiguous else {
            return ScrollViewportDetection(
                detectedViewport: nil,
                fallbackRect: fallbackRect,
                isAmbiguous: ambiguous
            )
        }

        let aligned = ScrollCaptureHelpers.pixelAlignedRect(
            best.frame,
            scale: geometry.scale,
            within: geometry.localBounds
        )

        return ScrollViewportDetection(
            detectedViewport: ScrollCaptureViewport(
                captureRect: aligned,
                confidence: best.confidence,
                usedAutoDetectedViewport: true,
                scrollElement: best.element,
                verticalScrollBar: best.verticalScrollBar
            ),
            fallbackRect: fallbackRect,
            isAmbiguous: false
        )
    }

    private struct CandidateAccumulator {
        let identifier: String
        let element: AXUIElement
        let frame: CGRect
        let role: String
        let verticalScrollBar: AXUIElement?
        let supportsValue: Bool
        var hitCount: Int
    }

    private struct AncestorCandidate {
        let identifier: String
        let element: AXUIElement
        let frame: CGRect
        let role: String
        let verticalScrollBar: AXUIElement?
        let supportsValue: Bool
    }

    private func walkAncestors(
        from element: AXUIElement,
        region: CGRect,
        geometry: ScrollScreenGeometry,
        visit: (AncestorCandidate) -> Void
    ) {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let resolvedCurrent = current else { break }
            guard let frame = localFrame(for: resolvedCurrent, geometry: geometry) else {
                current = elementAttribute(resolvedCurrent, kAXParentAttribute)
                continue
            }

            let role = (attribute(resolvedCurrent, kAXRoleAttribute) as? String) ?? ""
            let verticalScrollBar = elementAttribute(resolvedCurrent, kAXVerticalScrollBarAttribute)
            let supportsValue = attribute(resolvedCurrent, kAXValueAttribute) != nil
            let intersection = frame.intersection(region)

            if !intersection.isNull && frame.width >= 40 && frame.height >= 40 {
                var pid: pid_t = 0
                AXUIElementGetPid(resolvedCurrent, &pid)
                let identifier = "\(pid)-\(CFHash(resolvedCurrent))"
                visit(
                    AncestorCandidate(
                        identifier: identifier,
                        element: resolvedCurrent,
                        frame: frame,
                        role: role,
                        verticalScrollBar: verticalScrollBar,
                        supportsValue: supportsValue
                    )
                )
            }

            current = elementAttribute(resolvedCurrent, kAXParentAttribute)
        }
    }

    private func scoreCandidate(_ candidate: CandidateAccumulator, region: CGRect) -> Candidate? {
        let roleScore: Double
        switch candidate.role {
        case "AXWebArea":
            roleScore = 0.36
        case "AXScrollArea":
            roleScore = 0.34
        case "AXList":
            roleScore = 0.30
        case "AXOutline":
            roleScore = 0.28
        case "AXTable":
            roleScore = 0.28
        default:
            roleScore = 0.08
        }

        let selectionArea = max(1.0, region.width * region.height)
        let intersection = candidate.frame.intersection(region)
        let intersectionRatio = max(0, min(1, (intersection.width * intersection.height) / selectionArea))
        let coverageScore = min(0.25, Double(candidate.hitCount) / 9.0 * 0.25)
        let scrollScore = (candidate.verticalScrollBar != nil || candidate.supportsValue) ? 0.14 : 0
        let centerScore = candidate.frame.contains(CGPoint(x: region.midX, y: region.midY)) ? 0.05 : 0
        let confidence = min(1.0, roleScore + intersectionRatio * 0.25 + coverageScore + scrollScore + centerScore)

        return Candidate(
            element: candidate.element,
            frame: candidate.frame,
            role: candidate.role,
            verticalScrollBar: candidate.verticalScrollBar,
            supportsValue: candidate.supportsValue,
            hitCount: candidate.hitCount,
            confidence: confidence
        )
    }

    private func attribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func localFrame(
        for element: AXUIElement,
        geometry: ScrollScreenGeometry
    ) -> CGRect? {
        guard let position = cgPointAttribute(element, kAXPositionAttribute),
              let size = cgSizeAttribute(element, kAXSizeAttribute) else {
            return nil
        }

        return convertGlobalTopLeftRectToLocal(
            CGRect(origin: position, size: size),
            geometry: geometry
        )
    }

    private func convertGlobalTopLeftRectToLocal(
        _ rect: CGRect,
        geometry: ScrollScreenGeometry
    ) -> CGRect {
        let localX = rect.origin.x - geometry.frame.origin.x
        let appKitY = geometry.primaryScreenHeight - (rect.origin.y + rect.height)
        let localY = appKitY - geometry.frame.origin.y
        return CGRect(x: localX, y: localY, width: rect.width, height: rect.height)
    }

    private func cgPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        let typedValue = unsafeBitCast(axValue, to: AXValue.self)
        guard AXValueGetValue(typedValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func cgSizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        let typedValue = unsafeBitCast(axValue, to: AXValue.self)
        guard AXValueGetValue(typedValue, .cgSize, &size) else { return nil }
        return size
    }

}

private final class DefaultScrollDriver: ScrollDriving {
    private var hasStartedScroll = false

    func scroll(by pixels: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(pixels),
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }

        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: hasStartedScroll ? 2 : 1
        )
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        hasStartedScroll = true
        event.post(tap: .cghidEventTap)
    }

    func finishGesture() {
        guard hasStartedScroll,
              let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 0,
                wheel2: 0,
                wheel3: 0
              ) else {
            hasStartedScroll = false
            return
        }

        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
        hasStartedScroll = false
    }
}

private struct DefaultScrollSettling: ScrollSettling {
    private let initialDelayNanos: UInt64
    private let probeDelayNanos: UInt64
    private let maxProbes: Int

    init(
        initialDelayNanos: UInt64 = 120_000_000,
        probeDelayNanos: UInt64 = 40_000_000,
        maxProbes: Int = 6
    ) {
        self.initialDelayNanos = initialDelayNanos
        self.probeDelayNanos = probeDelayNanos
        self.maxProbes = maxProbes
    }

    func settle(
        region: CGRect,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        previousAcceptedFrame: ScrollCaptureHelpers.PreparedFrame?,
        expectedDisplacement: Int?,
        stickyHeaderHeight: Int,
        mode: ScrollCaptureMode,
        displacementEstimator: any ScrollDisplacementEstimating
    ) async throws -> ScrollSettledFrame? {
        let startDelay = mode == .manual ? 80_000_000 : initialDelayNanos
        try await Task.sleep(nanoseconds: startDelay)

        var probes: [ScrollCaptureHelpers.PreparedFrame] = []
        var lastProbe: ScrollCaptureHelpers.PreparedFrame?

        for probeIndex in 0..<maxProbes {
            try Task.checkCancellation()
            let image = try await captureFrame(region)
            guard let prepared = ScrollCaptureHelpers.prepareFrame(image) else {
                continue
            }

            if mode == .manual,
               probeIndex == 0,
               let previousAcceptedFrame {
                let movement = displacementEstimator.estimate(
                    previous: previousAcceptedFrame,
                    current: prepared,
                    options: .manual(
                        expectedDisplacement: expectedDisplacement,
                        stickyHeaderHeight: stickyHeaderHeight,
                        unstableBands: []
                    )
                )
                if !movement.isMeaningful {
                    return nil
                }
            }

            probes.append(prepared)

            if let lastProbe {
                let stability = displacementEstimator.estimate(
                    previous: lastProbe,
                    current: prepared,
                    options: .probeStability()
                )
                let hashSimilarity = ScrollCaptureHelpers.hashSimilarity(lastProbe, prepared)
                if stability.absoluteDisplacement <= 1 && hashSimilarity >= 0.95 {
                    return ScrollSettledFrame(
                        preparedFrame: prepared,
                        unstableBands: ScrollCaptureHelpers.detectUnstableBands(probes: probes),
                        stabilized: true,
                        probeCount: probes.count
                    )
                }
            }

            lastProbe = prepared
            if probeIndex + 1 < maxProbes {
                try await Task.sleep(nanoseconds: probeDelayNanos)
            }
        }

        guard let lastProbe else { return nil }
        return ScrollSettledFrame(
            preparedFrame: lastProbe,
            unstableBands: ScrollCaptureHelpers.detectUnstableBands(probes: probes),
            stabilized: false,
            probeCount: probes.count
        )
    }
}

private struct DefaultScrollDisplacementEstimator: ScrollDisplacementEstimating {
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

private struct DefaultScrollStitcher: ScrollStitching {
    func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult {
        try ScrollCaptureHelpers.stitch(
            frames: frames,
            maxCanvasHeight: maxCanvasHeight
        )
    }
}

private func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
    Swift.max(minimum, Swift.min(maximum, value))
}
