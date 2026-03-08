import CoreGraphics

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
