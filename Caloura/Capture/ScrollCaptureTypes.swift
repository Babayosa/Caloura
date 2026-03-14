import AppKit
import CoreGraphics
import Foundation

struct AXElementHandle: @unchecked Sendable {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    init?(attributeValue: AnyObject?) {
        guard let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }

        self.element = unsafeDowncast(attributeValue, to: AXUIElement.self)
    }
}

struct AXValueHandle: @unchecked Sendable {
    let value: AXValue

    init?(attributeValue: AnyObject?) {
        guard let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else {
            return nil
        }

        self.value = unsafeDowncast(attributeValue, to: AXValue.self)
    }

    func cgPoint() -> CGPoint? {
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    func cgSize() -> CGSize? {
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }
}

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

struct ScrollCaptureOutput: Sendable {
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

struct ScrollDisplacementOptions: Sendable {
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

enum ScrollCaptureThresholds {
    static let minimumAlignmentConfidence = 0.35
    static let minimumMeaningfulDisplacement = 12
}

struct ScrollDisplacementEstimate: Sendable {
    enum Method: String, Sendable {
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
        absoluteDisplacement >= ScrollCaptureThresholds.minimumMeaningfulDisplacement
            && confidence >= ScrollCaptureThresholds.minimumAlignmentConfidence
    }
}

struct ScrollFramePlacement: Sendable {
    let originY: Int
    let displacementFromPrevious: Int
}

struct ScrollCaptureFrame: Sendable {
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

struct ScrollStitchResult: Sendable {
    let image: CGImage
    let seamRepairCount: Int
}

struct ScrollSettledFrame: Sendable {
    let preparedFrame: ScrollCaptureHelpers.PreparedFrame
    let unstableBands: IndexSet
    let stabilized: Bool
    let probeCount: Int
}

struct ScrollScreenGeometry: Sendable {
    let frame: CGRect
    let scale: CGFloat
    let primaryScreenHeight: CGFloat

    var localBounds: CGRect {
        CGRect(origin: .zero, size: frame.size)
    }
}

struct ScrollCaptureViewport: Sendable {
    let captureRect: CGRect
    let confidence: Double
    let usedAutoDetectedViewport: Bool
    let scrollElement: AXElementHandle?
    let verticalScrollBar: AXElementHandle?
}

struct ScrollViewportDetection: Sendable {
    let detectedViewport: ScrollCaptureViewport?
    let fallbackRect: CGRect
    let isAmbiguous: Bool
}

enum ScrollCaptureError: LocalizedError, Sendable {
    case noScrollableViewport
    case noScrollTarget
    case unstableScrolling
    case framePreparationFailed
    case noFramesCaptured
    case canvasCreationFailed

    var userMessage: String {
        switch self {
        case .noScrollableViewport:
            return "No scrollable area was found in that selection. "
                + "Select only the scrolling content and try again."
        case .noScrollTarget:
            return "The selected area did not scroll. "
                + "Select a scrolling area and try again."
        case .unstableScrolling:
            return "Scroll capture could not stabilize the page. "
                + "Wait for motion to stop, or switch to manual mode."
        case .framePreparationFailed:
            return "Scroll capture could not prepare the captured frames. "
                + "Try again after the content finishes loading."
        case .noFramesCaptured:
            return "Scroll capture did not capture any content. Try again."
        case .canvasCreationFailed:
            return "Scroll capture could not assemble the final image. "
                + "Try a smaller region or lower the maximum scroll height."
        }
    }

    var errorDescription: String? {
        userMessage
    }
}

struct ScrollSettleRequest: Sendable {
    let region: CGRect
    let previousAcceptedFrame: ScrollCaptureHelpers.PreparedFrame?
    let expectedDisplacement: Int?
    let stickyHeaderHeight: Int
    let mode: ScrollCaptureMode
}

protocol ScrollViewportDetecting: Sendable {
    func detectViewport(
        in region: CGRect,
        geometry: ScrollScreenGeometry
    ) -> ScrollViewportDetection
}

protocol ScrollDriving: AnyObject, Sendable {
    func scroll(by pixels: Int)
    func finishGesture()
}

protocol ScrollSettling: Sendable {
    func settle(
        request: ScrollSettleRequest,
        captureFrame: @escaping @Sendable (CGRect) async throws -> CGImage,
        displacementEstimator: any ScrollDisplacementEstimating
    ) async throws -> ScrollSettledFrame?
}

protocol ScrollDisplacementEstimating: Sendable {
    func estimate(
        previous: ScrollCaptureHelpers.PreparedFrame,
        current: ScrollCaptureHelpers.PreparedFrame,
        options: ScrollDisplacementOptions
    ) -> ScrollDisplacementEstimate
}

protocol ScrollStitching: Sendable {
    func stitch(
        frames: [ScrollCaptureFrame],
        maxCanvasHeight: Int
    ) throws -> ScrollStitchResult
}
