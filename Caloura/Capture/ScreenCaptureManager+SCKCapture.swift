import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "ScreenCapture"
)

// Shared CIContext reused across all freeze snapshots. `CIContext` init is
// GPU-context setup (~10–50ms); allocating one per capture was a measurable
// freeze-latency tax.
// Extended-linear sRGB keeps wide-gamut (P3) and EDR pixel values unclipped
// through the CIContext pipeline. The output color space on `createCGImage`
// still tags the image with the display's native space (usually P3), so the
// freeze overlay renders without the green cast the sRGB working-space
// produced on P3 displays.
private let sharedFreezeCIContext: CIContext = {
    let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    return CIContext(options: [
        .workingColorSpace: workingSpace
    ])
}()

/// Seam for testing freeze-target application matching without constructing
/// real `SCRunningApplication` instances (which have no public initializer).
protocol FreezeShareableApplication {
    var processID: pid_t { get }
    var bundleIdentifier: String { get }
}

extension SCRunningApplication: FreezeShareableApplication {}

extension ScreenCaptureManager {

    // MARK: - SCK Capture

    private struct FrozenDisplayCaptureTarget {
        let resolvedScreen: ResolvedScreen
        let display: SCDisplay
        let excludedApplications: [SCRunningApplication]
    }

    func captureRectInDisplaySpace(
        rect: CGRect,
        screen: NSScreen?
    ) throws -> CGRect {
        let resolved = try resolveScreen(screen)
        let screenFrame = resolved.screen.frame
        let displayBounds = CGDisplayBounds(resolved.displayID)

        let globalY = displayBounds.origin.y
            + (screenFrame.height - rect.origin.y - rect.height)
        let globalX = displayBounds.origin.x + rect.origin.x

        return CGRect(
            x: globalX,
            y: globalY,
            width: rect.width,
            height: rect.height
        ).integral
    }

    func fullscreenRectInDisplaySpace(
        screen: NSScreen?
    ) throws -> CGRect {
        let resolved = try resolveScreen(screen)
        return CGDisplayBounds(resolved.displayID).integral
    }

    private func sckCaptureImage(
        in rect: CGRect
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(
                        throwing: CaptureError.noContent(
                            source: "ScreenCaptureKit screenshot"
                        )
                    )
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func freezeCaptureTarget(
        screen: NSScreen?,
        shareableContent: SCShareableContent
    ) throws -> FrozenDisplayCaptureTarget {
        let resolvedScreen = try resolveScreen(screen)
        guard let display = shareableContent.displays.first(where: {
            $0.displayID == resolvedScreen.displayID
        }) else {
            throw CaptureError.captureFailed(
                "Failed to resolve shareable display for freeze snapshot"
            )
        }

        let excludedApplications = Self.freezeExcludedApplications(
            in: shareableContent.applications,
            currentProcessID: getpid(),
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )

        return FrozenDisplayCaptureTarget(
            resolvedScreen: resolvedScreen,
            display: display,
            excludedApplications: excludedApplications
        )
    }

    static func freezeExcludedApplications<App: FreezeShareableApplication>(
        in applications: [App],
        currentProcessID: pid_t,
        currentBundleIdentifier: String?
    ) -> [App] {
        guard let currentApplication = applications.first(where: {
            $0.processID == currentProcessID
                || (currentBundleIdentifier != nil
                    && $0.bundleIdentifier == currentBundleIdentifier)
        }) else {
            // First capture after launch: an agent app may not yet appear in
            // SCShareableContent.applications. Capturing without
            // self-exclusion beats silently losing the freeze backdrop.
            logger.warning(
                "Current app not in shareable applications; capturing freeze snapshot without self-exclusion"
            )
            return []
        }
        return [currentApplication]
    }

    func makeFreezeSnapshotConfiguration(
        for screen: NSScreen
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Freeze snapshot is what the user sees behind the dimming + selection
        // overlay — it must render at native pixel density, otherwise Retina
        // users see a blurry, upsampled backdrop when capture mode opens.
        let scale = screen.backingScaleFactor
        configuration.width = max(
            1,
            Int(ceil(screen.frame.width * scale))
        )
        configuration.height = max(
            1,
            Int(ceil(screen.frame.height * scale))
        )
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.shouldBeOpaque = true
        return configuration
    }

    func sckCaptureFullScreen(
        screen: NSScreen?
    ) async throws -> CGImage {
        let rect = try fullscreenRectInDisplaySpace(screen: screen)
        return try await sckCaptureImage(in: rect)
    }

    func captureFrozenDisplaySnapshot(
        screen: NSScreen? = nil
    ) async throws -> CGImage {
        guard !sckFailed else {
            throw CaptureError.captureFailed(
                "Freeze snapshot unavailable while ScreenCaptureKit is disabled"
            )
        }

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await self.shareableContent()
        } catch {
            handleSCKFailure(error, context: .shareableContentLookup)
            if let captureError = captureErrorForSCKFailure(error) {
                throw captureError
            }
            throw error
        }

        let target = try freezeCaptureTarget(
            screen: screen,
            shareableContent: shareableContent
        )

        let filter = SCContentFilter(
            display: target.display,
            excludingApplications: target.excludedApplications,
            exceptingWindows: []
        )
        let configuration = makeFreezeSnapshotConfiguration(
            for: target.resolvedScreen.screen
        )
        let colorSpace = target.resolvedScreen.screen.colorSpace?.cgColorSpace

        do {
            return try await captureFrozenDisplaySnapshot(
                contentFilter: filter,
                configuration: configuration,
                colorSpace: colorSpace
            )
        } catch is CancellationError {
            logger.debug("Freeze snapshot cancelled before completion")
            throw CaptureError.cancelled
        } catch {
            logger.warning(
                "SCK captureFrozenDisplaySnapshot failed: \(error.localizedDescription)"
            )
            handleSCKFailure(error, context: .freezeSnapshot)
            if let captureError = captureErrorForSCKFailure(error) {
                throw captureError
            }
            throw error
        }
    }

    func sckCaptureArea(
        rect: CGRect,
        screen: NSScreen?
    ) async throws -> CGImage {
        let captureRect = try captureRectInDisplaySpace(
            rect: rect,
            screen: screen
        )
        return try await sckCaptureImage(in: captureRect)
    }

    func sckCaptureAreaInDisplaySpace(
        rect: CGRect
    ) async throws -> CGImage {
        try await sckCaptureImage(in: rect.integral)
    }

}

final class OneShotFrozenDisplayStreamCapture: NSObject,
    FrozenDisplaySnapshotOperation,
    SCStreamDelegate,
    SCStreamOutput,
    @unchecked Sendable {
    private let contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let outputColorSpace: CGColorSpace
    private let sampleQueue = DispatchQueue(
        label: "com.caloura.app.freeze-stream-capture"
    )
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var finished = false

    init(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration,
        colorSpace: CGColorSpace? = nil
    ) {
        self.contentFilter = contentFilter
        self.configuration = configuration
        self.outputColorSpace = colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    func captureImage() async throws -> CGImage {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            guard self.continuation == nil else {
                stateLock.unlock()
                continuation.resume(
                    throwing: CaptureError.captureFailed(
                        "Freeze snapshot operation was reused unexpectedly"
                    )
                )
                return
            }

            self.continuation = continuation
            stateLock.unlock()
            self.startStream()
        }
    }

    func cancel() async {
        guard !isFinished else { return }
        complete(with: .failure(CancellationError()))
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        handleSampleBuffer(sampleBuffer)
    }

    nonisolated func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {
        if isFinished {
            logger.debug(
                "Ignoring late freeze-stream stop callback: \(error.localizedDescription)"
            )
            return
        }
        complete(with: .failure(error))
    }

    private func startStream() {
        do {
            let stream = SCStream(
                filter: contentFilter,
                configuration: configuration,
                delegate: self
            )
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: sampleQueue
            )
            stateLock.lock()
            guard !finished else {
                stateLock.unlock()
                tearDownUnstartedStream(stream)
                return
            }
            self.stream = stream
            let callbackQueue = sampleQueue
            stream.startCapture { [weak self] error in
                guard let operation = self else { return }
                callbackQueue.async {
                    if let error {
                        operation.complete(with: .failure(error))
                    } else if operation.isFinished {
                        logger.debug(
                            "Freeze-stream start completed after operation already finished"
                        )
                    }
                }
            }
            stateLock.unlock()
        } catch {
            complete(with: .failure(error))
        }
    }

    private func handleSampleBuffer(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard !isFinished else {
            logger.debug("Ignoring late freeze-stream sample after completion")
            return
        }

        do {
            guard isUsableFrame(sampleBuffer) else { return }
            let image = try makeImage(from: sampleBuffer)
            complete(with: .success(image))
        } catch {
            complete(with: .failure(error))
        }
    }

    private func isUsableFrame(
        _ sampleBuffer: CMSampleBuffer
    ) -> Bool {
        guard let attachments = (
            CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]]
        )?.first,
        let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
        let status = SCFrameStatus(rawValue: statusRaw) else {
            return true
        }

        switch status {
        case .blank, .stopped, .suspended:
            return false
        case .complete, .idle, .started:
            return true
        @unknown default:
            return true
        }
    }

    private func makeImage(
        from sampleBuffer: CMSampleBuffer
    ) throws -> CGImage {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw CaptureError.noContent(
                source: "Freeze snapshot stream sample"
            )
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard let cgImage = sharedFreezeCIContext.createCGImage(
            image,
            from: extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else {
            throw CaptureError.noContent(
                source: "Freeze snapshot stream image conversion"
            )
        }

        return cgImage
    }

    private func complete(
        with result: Result<CGImage, Error>
    ) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        stateLock.unlock()

        let completion = FrozenDisplaySnapshotCompletion(
            continuation: continuation,
            result: result
        )

        guard let stream else {
            completion.resume()
            return
        }

        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            logger.debug(
                "Freeze-stream output removal failed during teardown: \(error.localizedDescription)"
            )
        }

        stream.stopCapture { error in
            if let error {
                logger.debug(
                    "Freeze-stream stop failed during teardown: \(error.localizedDescription)"
                )
            }
            completion.resume()
        }
    }

    private func tearDownUnstartedStream(_ stream: SCStream) {
        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            logger.debug(
                "Freeze-stream output removal failed before start: \(error.localizedDescription)"
            )
        }
    }

    private var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }
}

private struct FrozenDisplaySnapshotCompletion: @unchecked Sendable {
    let continuation: CheckedContinuation<CGImage, Error>?
    let result: Result<CGImage, Error>

    func resume() {
        guard let continuation else { return }
        switch result {
        case .success(let image):
            continuation.resume(returning: image)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
