import CoreGraphics

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

    struct Request: Sendable {
        let region: CGRect
        let geometry: ScrollScreenGeometry
        let config: Config
        let targetAppName: String?

        init(
            region: CGRect,
            geometry: ScrollScreenGeometry,
            config: Config,
            targetAppName: String? = nil
        ) {
            self.region = region
            self.geometry = geometry
            self.config = config
            self.targetAppName = targetAppName
        }
    }

    struct Session: Sendable {
        let request: Request
        let control: ScrollCaptureControl
        let captureFrame: @Sendable (CGRect) async throws -> CGImage
        let onProgress: @MainActor @Sendable (ScrollCaptureProgress) -> Void
    }

    enum Result: @unchecked Sendable {
        case success(ScrollCaptureOutput)
        case cancelled
        case failed(Error)
    }

    enum AutomaticCaptureResult {
        case completed(ScrollTerminationReason)
        case fallbackToManual(String)
    }

    struct ProgressUpdate: Sendable {
        let phase: ScrollCapturePhase
        let mode: ScrollCaptureMode
        let frames: Int
        let estimatedHeight: Int
        let status: String
        let allowManualSwitch: Bool

        var progress: ScrollCaptureProgress {
            ScrollCaptureProgress(
                phase: phase,
                mode: mode,
                frameCount: frames,
                estimatedHeight: estimatedHeight,
                status: status,
                canSwitchToManual: allowManualSwitch && mode == .automatic,
                canFinishManual: mode == .manual
            )
        }
    }

    let viewportDetector: any ScrollViewportDetecting
    let scrollDriver: any ScrollDriving
    let settling: any ScrollSettling
    let displacementEstimator: any ScrollDisplacementEstimating
    let stitcher: any ScrollStitching

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
}

func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
    Swift.max(minimum, Swift.min(maximum, value))
}
