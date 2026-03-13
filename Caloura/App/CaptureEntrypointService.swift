import AppKit
import os.log
import ScreenCaptureKit

let captureEntryLogger = Logger(subsystem: "com.caloura.app", category: "CaptureEntry")

@MainActor
final class CaptureEntrypointService {
    typealias HandlePermissionFailureFn = CapturePipeline.HandlePermissionFailureFn
    typealias SelectWindowCaptureFn = CapturePipeline.SelectWindowCaptureFn
    typealias MakeAreaCaptureSessionFn = CapturePipeline.MakeAreaCaptureSessionFn
    typealias MakeFullscreenCaptureSessionFn = CapturePipeline.MakeFullscreenCaptureSessionFn
    typealias MakeWindowCaptureSessionFn = CapturePipeline.MakeWindowCaptureSessionFn
    typealias PerformAreaCaptureFn = @MainActor (
        CGRect,
        NSScreen?,
        CapturePerformanceRecorder.Session
    ) async -> Void
    typealias PerformFrozenAreaCaptureFn = @MainActor (
        CGRect,
        NSScreen,
        CGImage,
        CapturePerformanceRecorder.Session
    ) async -> Void
    typealias PerformFullscreenCaptureFn = @MainActor (
        NSScreen?,
        Bool,
        CapturePerformanceRecorder.Session?
    ) async -> Void
    typealias PerformWindowCaptureFn = @MainActor (
        @escaping @MainActor () async throws -> CGImage,
        CapturePerformanceRecorder.Session?
    ) async -> Void
    typealias FreezeScreensFn = @MainActor (CFAbsoluteTime) async -> [NSScreen: CGImage]
    typealias PrewarmWindowContentFn = @MainActor () async -> Void
    typealias CaptureScrollFn = @MainActor () -> Void
    typealias ElapsedMillisecondsFn = (CFAbsoluteTime) -> Double
    typealias RecordMetricFn = (PerformanceMetricStage, Double) -> Void
    typealias IsSameObjectFn = (AnyObject?, AnyObject?) -> Bool
    typealias ScreensProviderFn = () -> [NSScreen]
    typealias MainScreenProviderFn = () -> NSScreen?

    let appState: AppState
    let capturePerformanceRecorder: CapturePerformanceRecorder
    let sessionState: CaptureSessionState
    let handlePermissionFailure: HandlePermissionFailureFn
    let selectWindowCapture: SelectWindowCaptureFn
    let makeAreaCaptureSession: MakeAreaCaptureSessionFn
    let makeFullscreenCaptureSession: MakeFullscreenCaptureSessionFn
    let makeWindowCaptureSession: MakeWindowCaptureSessionFn
    let performAreaCapture: PerformAreaCaptureFn
    let performFrozenAreaCapture: PerformFrozenAreaCaptureFn
    let performFullscreenCapture: PerformFullscreenCaptureFn
    let performWindowCapture: PerformWindowCaptureFn
    let freezeScreens: FreezeScreensFn
    let prewarmWindowContent: PrewarmWindowContentFn
    let captureScroll: CaptureScrollFn
    let elapsedMilliseconds: ElapsedMillisecondsFn
    let recordMetric: RecordMetricFn
    let isSameObject: IsSameObjectFn
    let screenCountProvider: () -> Int
    let screensProvider: ScreensProviderFn
    let mainScreenProvider: MainScreenProviderFn
    let freezeScreensEnabled: Bool

    init(
        appState: AppState,
        capturePerformanceRecorder: CapturePerformanceRecorder,
        sessionState: CaptureSessionState,
        handlePermissionFailure: @escaping HandlePermissionFailureFn,
        selectWindowCapture: @escaping SelectWindowCaptureFn,
        makeAreaCaptureSession: @escaping MakeAreaCaptureSessionFn,
        makeFullscreenCaptureSession: @escaping MakeFullscreenCaptureSessionFn,
        makeWindowCaptureSession: @escaping MakeWindowCaptureSessionFn,
        performAreaCapture: @escaping PerformAreaCaptureFn,
        performFrozenAreaCapture: @escaping PerformFrozenAreaCaptureFn,
        performFullscreenCapture: @escaping PerformFullscreenCaptureFn,
        performWindowCapture: @escaping PerformWindowCaptureFn,
        freezeScreens: @escaping FreezeScreensFn,
        prewarmWindowContent: @escaping PrewarmWindowContentFn,
        captureScroll: @escaping CaptureScrollFn,
        elapsedMilliseconds: @escaping ElapsedMillisecondsFn,
        recordMetric: @escaping RecordMetricFn,
        isSameObject: @escaping IsSameObjectFn,
        screenCountProvider: @escaping () -> Int,
        screensProvider: @escaping ScreensProviderFn,
        mainScreenProvider: @escaping MainScreenProviderFn,
        freezeScreensEnabled: Bool
    ) {
        self.appState = appState
        self.capturePerformanceRecorder = capturePerformanceRecorder
        self.sessionState = sessionState
        self.handlePermissionFailure = handlePermissionFailure
        self.selectWindowCapture = selectWindowCapture
        self.makeAreaCaptureSession = makeAreaCaptureSession
        self.makeFullscreenCaptureSession = makeFullscreenCaptureSession
        self.makeWindowCaptureSession = makeWindowCaptureSession
        self.performAreaCapture = performAreaCapture
        self.performFrozenAreaCapture = performFrozenAreaCapture
        self.performFullscreenCapture = performFullscreenCapture
        self.performWindowCapture = performWindowCapture
        self.freezeScreens = freezeScreens
        self.prewarmWindowContent = prewarmWindowContent
        self.captureScroll = captureScroll
        self.elapsedMilliseconds = elapsedMilliseconds
        self.recordMetric = recordMetric
        self.isSameObject = isSameObject
        self.screenCountProvider = screenCountProvider
        self.screensProvider = screensProvider
        self.mainScreenProvider = mainScreenProvider
        self.freezeScreensEnabled = freezeScreensEnabled
    }

    func captureArea() {
        guard beginCaptureIfIdle() else { return }
        let sessionID = sessionState.beginTrackedSession()
        let entryStart = CFAbsoluteTimeGetCurrent()
        let performanceSession = capturePerformanceRecorder.beginSession(mode: .area)
        captureEntryLogger.debug("Capture entry: request received")

        let coordinator = makeAreaCaptureCoordinator(
            sessionID: sessionID,
            entryStart: entryStart,
            performanceSession: performanceSession
        )
        sessionState.areaCaptureSession?.dismiss()
        sessionState.areaCaptureSession = coordinator

        presentAreaCaptureCoordinator(coordinator, entryStart: entryStart)

        guard freezeScreensEnabled else { return }
        loadAreaCaptureFrozenImages(
            for: coordinator,
            sessionID: sessionID,
            entryStart: entryStart
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
            sessionState.screenOverlays = coordinator.overlayWindows
            return
        }

        capturePerformanceRecorder.mark(.appActivated, in: performanceSession)
        Task { @MainActor [weak self] in
            await self?.performFullscreenCapture(
                nil,
                false,
                performanceSession
            )
        }
    }

    func captureWindow() {
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
                await self.performWindowCapture(captureOperation, performanceSession)
            case .cancelled:
                self.finishInterruptedCapture(performanceSession)
            case .failedToStart:
                self.finishInterruptedCapture(performanceSession)
                await self.handlePermissionFailure()
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
            await self?.performAreaCapture(rect, screen, performanceSession)
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
                await self.performFullscreenCapture(nil, true, nil)
            case .window:
                self.appState.isCapturing = false
                self.captureWindow()
            case .scroll:
                self.appState.isCapturing = false
                self.captureScroll()
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
}
