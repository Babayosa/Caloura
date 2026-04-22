import AppKit
import os.log
import ScreenCaptureKit

@MainActor
final class CaptureEntrypointService {
    nonisolated static let logger = Logger(subsystem: "com.caloura.app", category: "CaptureEntry")
    typealias HandlePermissionFailureFn = CapturePipeline.HandlePermissionFailureFn
    typealias SelectWindowCaptureFn = CapturePipeline.SelectWindowCaptureFn
    typealias MakeAreaCaptureSessionFn = CapturePipeline.MakeAreaCaptureSessionFn
    typealias MakeFullscreenCaptureSessionFn = CapturePipeline.MakeFullscreenCaptureSessionFn
    typealias MakeWindowCaptureSessionFn = CapturePipeline.MakeWindowCaptureSessionFn
    typealias PrewarmWindowContentFn = @MainActor () async -> Void
    typealias ScreensProviderFn = () -> [NSScreen]
    typealias MainScreenProviderFn = () -> NSScreen?
    typealias DelaySleeperFn = (UInt64) async -> Void

    let appState: AppState
    let capturePerformanceRecorder: CapturePerformanceRecorder
    let sessionState: CaptureSessionState
    let handlePermissionFailure: HandlePermissionFailureFn
    let selectWindowCapture: SelectWindowCaptureFn
    let makeAreaCaptureSession: MakeAreaCaptureSessionFn
    let makeFullscreenCaptureSession: MakeFullscreenCaptureSessionFn
    let makeWindowCaptureSession: MakeWindowCaptureSessionFn
    let executionService: CaptureExecutionService
    let captureManager: ScreenCaptureManaging
    let freezeService: CaptureFreezeService
    let prewarmWindowContent: PrewarmWindowContentFn
    let metricsRecorder: CaptureMetricsRecorder
    let screenCountProvider: () -> Int
    let screensProvider: ScreensProviderFn
    let mainScreenProvider: MainScreenProviderFn
    let delaySleeper: DelaySleeperFn
    let freezeScreensEnabled: Bool
    let settings: AppSettings

    init(
        appState: AppState,
        capturePerformanceRecorder: CapturePerformanceRecorder,
        sessionState: CaptureSessionState,
        handlePermissionFailure: @escaping HandlePermissionFailureFn,
        selectWindowCapture: @escaping SelectWindowCaptureFn,
        makeAreaCaptureSession: @escaping MakeAreaCaptureSessionFn,
        makeFullscreenCaptureSession: @escaping MakeFullscreenCaptureSessionFn,
        makeWindowCaptureSession: @escaping MakeWindowCaptureSessionFn,
        executionService: CaptureExecutionService,
        captureManager: ScreenCaptureManaging,
        freezeService: CaptureFreezeService,
        prewarmWindowContent: @escaping PrewarmWindowContentFn,
        metricsRecorder: CaptureMetricsRecorder,
        screenCountProvider: @escaping () -> Int,
        screensProvider: @escaping ScreensProviderFn,
        mainScreenProvider: @escaping MainScreenProviderFn,
        delaySleeper: @escaping DelaySleeperFn = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        freezeScreensEnabled: Bool,
        settings: AppSettings
    ) {
        self.appState = appState
        self.capturePerformanceRecorder = capturePerformanceRecorder
        self.sessionState = sessionState
        self.handlePermissionFailure = handlePermissionFailure
        self.selectWindowCapture = selectWindowCapture
        self.makeAreaCaptureSession = makeAreaCaptureSession
        self.makeFullscreenCaptureSession = makeFullscreenCaptureSession
        self.makeWindowCaptureSession = makeWindowCaptureSession
        self.executionService = executionService
        self.captureManager = captureManager
        self.freezeService = freezeService
        self.prewarmWindowContent = prewarmWindowContent
        self.metricsRecorder = metricsRecorder
        self.screenCountProvider = screenCountProvider
        self.screensProvider = screensProvider
        self.mainScreenProvider = mainScreenProvider
        self.delaySleeper = delaySleeper
        self.freezeScreensEnabled = freezeScreensEnabled
        self.settings = settings
    }

    func captureArea() {
        guard beginCaptureIfIdle() else { return }
        let sessionID = sessionState.beginTrackedSession()
        let entryStart = CFAbsoluteTimeGetCurrent()
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .area)
        Self.logger.debug("Capture entry: request received")

        let coordinator = makeAreaCaptureCoordinator(
            sessionID: sessionID,
            entryStart: entryStart,
            performanceSession: performanceSession
        )
        sessionState.areaCaptureSession?.dismiss()
        sessionState.areaCaptureSession = coordinator

        let presented = presentAreaCaptureCoordinator(
            coordinator,
            entryStart: entryStart,
            performanceSession: performanceSession
        )
        guard presented else { return }

        guard freezeScreensEnabled, !settings.lowProfileCaptureEnabled else { return }
        loadAreaCaptureFrozenImages(
            for: coordinator,
            sessionID: sessionID,
            entryStart: entryStart,
            performanceSession: performanceSession
        )
    }

    func captureFullscreen() {
        guard beginCaptureIfIdle() else { return }
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .fullscreen)

        if screenCountProvider() > 1 {
            let coordinator = makeFullscreenCaptureCoordinator(
                performanceSession: performanceSession
            )
            sessionState.fullscreenCaptureSession?.dismiss()
            sessionState.fullscreenCaptureSession = coordinator
            coordinator.present()
            // Mirror the area path: if the overlay presenter returned no
            // overlays (all displays disconnected mid-flow), unwind cleanly
            // instead of leaving isCapturing stuck-true.
            guard !coordinator.overlayWindows.isEmpty else {
                Self.logger.error(
                    "Capture entry: no active displays — aborting fullscreen capture"
                )
                appState.statusMessage = "No active display — capture cancelled."
                coordinator.dismiss()
                sessionState.fullscreenCaptureSession = nil
                finishInterruptedCapture(performanceSession)
                return
            }
            sessionState.screenOverlays = coordinator.overlayWindows
            return
        }

        capturePerformanceRecorder.mark(.appActivated, in: performanceSession)
        Task { @MainActor [weak self] in
            await self?.performFullscreenCapture(
                screen: nil,
                dismissDelay: false,
                performanceSession: performanceSession
            )
        }
    }

    func captureWindow() {
        guard !settings.lowProfileCaptureEnabled else {
            appState.statusMessage = "Window capture unavailable in low-profile mode"
            appState.isCapturing = false
            return
        }
        guard beginCaptureIfIdle() else { return }
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .window)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let coordinator = self.makeWindowCaptureSession(
                performanceSession,
                { await self.prewarmWindowContent() },
                self.selectWindowCapture
            )
            switch await coordinator.pick() {
            case .selected(let captureOperation):
                await self.performWindowCapture(capture: captureOperation, performanceSession: performanceSession)
            case .cancelled:
                self.finishInterruptedCapture(performanceSession)
            case .failedToStart:
                // Transient picker failure. Do NOT cascade into the
                // permission-repair flow — that path shows a modal alert
                // and resets TCC, which is destructive when the picker
                // just had a single transient miss. Surface a soft status
                // message only; the next hotkey press gets a fresh picker.
                self.appState.statusMessage = "Window picker unavailable. Try again."
                self.finishInterruptedCapture(performanceSession)
            }
        }
    }

    func captureRepeat() {
        guard let rect = appState.lastCaptureRect else {
            appState.statusMessage = "No previous area capture to repeat."
            return
        }
        guard beginCaptureIfIdle() else { return }

        if let screen = appState.lastCaptureScreen,
           !screensProvider().contains(where: { $0 == screen }) {
            appState.lastCaptureScreen = nil
        }
        let screen = appState.lastCaptureScreen ?? mainScreenProvider()
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .area)

        Task { @MainActor [weak self] in
            await self?.performAreaCapture(rect: rect, screen: screen, performanceSession: performanceSession)
        }
    }

    func captureDelayed(seconds: Int, mode: CaptureMode) {
        guard beginCaptureIfIdle() else { return }

        let delay = max(1, min(seconds, 10))
        appState.isCountingDown = true
        appState.countdownRemaining = delay
        appState.statusMessage = "Capturing in \(delay)s..."

        CountdownOverlay.shared.show(seconds: delay) { [weak self] in
            self?.cancelDelayedCapture()
        }

        sessionState.replaceDelayedCaptureTask(Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: delay, through: 1, by: -1) {
                if Task.isCancelled { return }
                self.appState.statusMessage = "Capturing in \(remaining)s..."
                self.appState.countdownRemaining = remaining
                CountdownOverlay.shared.updateCount(remaining)
                await self.delaySleeper(1_000_000_000)
            }

            if Task.isCancelled { return }

            self.appState.isCountingDown = false
            self.appState.countdownRemaining = 0
            CountdownOverlay.shared.dismiss()
            self.sessionState.clearDelayedCaptureTask()

            guard !Task.isCancelled else { return }

            switch mode {
            case .area:
                self.appState.isCapturing = false
                self.captureArea()
            case .fullscreen:
                await self.performFullscreenCapture(screen: nil, dismissDelay: true, performanceSession: nil)
            case .window:
                self.appState.isCapturing = false
                self.captureWindow()
            }
        })
    }

    func cancelDelayedCapture() {
        sessionState.replaceDelayedCaptureTask(nil)
        appState.isCountingDown = false
        appState.countdownRemaining = 0
        appState.isCapturing = false
        appState.statusMessage = "Countdown cancelled"
        CountdownOverlay.shared.dismiss()
    }

    private func beginCaptureIfIdle() -> Bool {
        guard !appState.isCapturing else { return false }
        appState.isCapturing = true
        return true
    }

    func finishInterruptedCapture(
        _ performanceSession: CapturePerformanceRecorder.Session
    ) {
        appState.isCapturing = false
        capturePerformanceRecorder.finishSession(performanceSession)
    }

    // MARK: - Perform Captures

    func performAreaCapture(
        rect: CGRect,
        screen: NSScreen?,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await executionService.performCapture(mode: .area, performanceSession: performanceSession) {
            try await self.captureManager.captureArea(
                rect: rect, screen: screen
            )
        }
    }

    /// Compute the crop rect in image-pixel coordinates from a screen-local
    /// selection rect and the actual frozen image width.
    static func frozenImageCropRect(
        selectionRect: CGRect,
        screenHeight: CGFloat,
        imageWidth: Int,
        screenWidth: CGFloat
    ) -> CGRect {
        let imageScale = CGFloat(imageWidth) / screenWidth
        let flippedY = screenHeight - selectionRect.origin.y - selectionRect.height
        return CGRect(
            x: selectionRect.origin.x * imageScale,
            y: flippedY * imageScale,
            width: selectionRect.width * imageScale,
            height: selectionRect.height * imageScale
        ).integral
    }

    /// Crop from an already-captured frozen image (for freeze capture mode)
    func performFrozenAreaCapture(
        rect: CGRect,
        screen: NSScreen,
        frozenImage: CGImage,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await executionService.performCapture(mode: .area, performanceSession: performanceSession) {
            let imageRect = Self.frozenImageCropRect(
                selectionRect: rect,
                screenHeight: screen.frame.height,
                imageWidth: frozenImage.width,
                screenWidth: screen.frame.width
            )

            guard let croppedImage = frozenImage.cropping(to: imageRect) else {
                // Frozen image dimensions don't match — fall back to live capture
                return try await self.captureManager.captureArea(
                    rect: rect, screen: screen
                )
            }
            return croppedImage
        }
    }

    func performFullscreenCapture(
        screen: NSScreen? = nil,
        dismissDelay: Bool = false,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        if dismissDelay {
            // Brief delay to let menu bar close / overlays dismiss
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        await executionService.performCapture(
            mode: .fullscreen,
            performanceSession: performanceSession
        ) {
            try await self.captureManager.captureFullScreen(screen: screen)
        }
    }

    func performWindowCapture(
        capture: @escaping @MainActor () async throws -> CGImage,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async {
        await executionService.performCapture(mode: .window, performanceSession: performanceSession) {
            try await capture()
        }
    }
}
