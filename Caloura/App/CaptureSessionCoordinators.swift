import AppKit
import ScreenCaptureKit

@MainActor
protocol AreaCaptureSessionHandling: AnyObject {
    var overlayWindows: [CaptureOverlayWindow] { get }

    func present(windows: [CaptureOverlayWindow], suppressDimming: Bool)
    func updateFrozenImages(_ images: [NSScreen: CGImage])
    func dismiss()
}

@MainActor
protocol FullscreenCaptureSessionHandling: AnyObject {
    var overlayWindows: [ScreenSelectionOverlayWindow] { get }

    func present()
    func dismiss()
}

@MainActor
protocol WindowCaptureSessionHandling: AnyObject {
    func pick() async -> WindowCaptureSessionCoordinator.SelectionResult
}

@MainActor
final class AreaCaptureSessionCoordinator {
    typealias SelectionHandler = @MainActor (CGRect, NSScreen, CGImage?) async -> Void
    typealias CancelHandler = @MainActor () -> Void
    typealias EventHandler = @MainActor () -> Void

    private let session: CapturePerformanceRecorder.Session
    private let performanceRecorder: CapturePerformanceRecorder
    private let cursorController: CaptureCursorControlling
    private let onSelection: SelectionHandler
    private let onCancel: CancelHandler
    private let onFirstInteraction: EventHandler?

    private(set) var overlayWindows: [CaptureOverlayWindow] = []
    private var frozenImages: [NSScreen: CGImage] = [:]
    private var firstInteractionRecorded = false
    private var cursorSession: (any CaptureCursorSessionHandling)?

    init(
        session: CapturePerformanceRecorder.Session,
        performanceRecorder: CapturePerformanceRecorder,
        cursorController: CaptureCursorControlling,
        onSelection: @escaping SelectionHandler,
        onCancel: @escaping CancelHandler,
        onFirstInteraction: EventHandler? = nil
    ) {
        self.session = session
        self.performanceRecorder = performanceRecorder
        self.cursorController = cursorController
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.onFirstInteraction = onFirstInteraction
    }

    func present(windows: [CaptureOverlayWindow], suppressDimming: Bool = false) {
        firstInteractionRecorded = false
        frozenImages = [:]
        overlayWindows = windows

        // Cursor session MUST start before any overlay is ordered front. Otherwise
        // becomeKey() fires synchronously inside makeKeyAndOrderFront(nil), and
        // CaptureOverlayWindow.primeCrosshair()'s scheduleReprime() silently
        // no-ops because cursorActive is still false.
        cursorSession?.end()
        cursorSession = cursorController.startCrosshairSession()

        for (index, window) in windows.enumerated() {
            if suppressDimming {
                window.isDimmingSuppressed = true
            }

            window.onRegionSelected = { [weak self] rect, screen in
                guard let self else { return }
                self.releaseOverlays()
                Task { @MainActor in
                    await self.onSelection(rect, screen, self.frozenImages[screen])
                }
            }
            window.onCancelled = { [weak self] in
                guard let self else { return }
                self.releaseOverlays()
                Task { @MainActor in
                    self.onCancel()
                }
            }
            window.onFirstMouseDown = { [weak self] in
                guard let self else { return }
                guard !self.firstInteractionRecorded else { return }
                self.firstInteractionRecorded = true
                self.performanceRecorder.mark(.firstInteraction, in: self.session)
                self.onFirstInteraction?()
            }

            if index == 0 {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }

        // Force synchronous cursor rect registration on all overlays.
        // On pooled window reuse, becomeKey()/viewDidMoveToWindow may
        // not fire, leaving cursor rects stale. invalidateCursorRects
        // is async and unreliable; calling resetCursorRects() directly
        // registers the crosshair rect immediately so AppKit's cursor
        // tracking applies it without waiting for the next run loop pass.
        for window in windows {
            if let contentView = window.contentView {
                contentView.discardCursorRects()
                contentView.resetCursorRects()
                window.invalidateCursorRects(for: contentView)
            }
        }

        cursorController.handleCursorUpdate()
        cursorController.scheduleReprime()
        performanceRecorder.mark(.overlayVisible, in: session)
    }

    func updateFrozenImages(_ images: [NSScreen: CGImage]) {
        self.frozenImages = images
        for window in overlayWindows {
            if let screen = window.screen, let image = images[screen] {
                window.revealFrozenImage(image)
            } else {
                window.isDimmingSuppressed = false
            }
        }
    }

    func dismiss() {
        releaseOverlays()
    }

    private func releaseOverlays() {
        for overlay in overlayWindows {
            overlay.tearDownHandlers()
            overlay.orderOut(nil)
        }
        overlayWindows = []
        cursorSession?.end()
        cursorSession = nil
    }
}

extension AreaCaptureSessionCoordinator: AreaCaptureSessionHandling {}

@MainActor
final class FullscreenCaptureSessionCoordinator {
    typealias SelectionHandler = @MainActor (NSScreen) async -> Void
    typealias CancelHandler = @MainActor () -> Void
    typealias OverlayPresenter = @MainActor (
        CaptureCursorControlling?,
        @escaping (NSScreen) -> Void,
        @escaping () -> Void
    ) -> [ScreenSelectionOverlayWindow]

    private let session: CapturePerformanceRecorder.Session
    private let performanceRecorder: CapturePerformanceRecorder
    private let cursorController: CaptureCursorControlling
    private let onSelection: SelectionHandler
    private let onCancel: CancelHandler
    private let overlayPresenter: OverlayPresenter

    private(set) var overlayWindows: [ScreenSelectionOverlayWindow] = []
    private var cursorSession: (any CaptureCursorSessionHandling)?

    private static func defaultOverlayPresenter(
        cursorController: CaptureCursorControlling?,
        onScreenSelected: @escaping (NSScreen) -> Void,
        onCancelled: @escaping () -> Void
    ) -> [ScreenSelectionOverlayWindow] {
        ScreenSelectionOverlayWindow.showOnAllScreens(
            cursorController: cursorController,
            onScreenSelected: onScreenSelected,
            onCancelled: onCancelled
        )
    }

    init(
        session: CapturePerformanceRecorder.Session,
        performanceRecorder: CapturePerformanceRecorder,
        cursorController: CaptureCursorControlling,
        onSelection: @escaping SelectionHandler,
        onCancel: @escaping CancelHandler,
        overlayPresenter: OverlayPresenter? = nil
    ) {
        self.session = session
        self.performanceRecorder = performanceRecorder
        self.cursorController = cursorController
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.overlayPresenter = overlayPresenter ?? Self.defaultOverlayPresenter
    }

    func present() {
        // Start must run before the overlay presenter
        // calls makeKeyAndOrderFront so primeCrosshair's reprime can take.
        cursorSession?.end()
        cursorSession = cursorController.startCrosshairSession()
        overlayWindows = overlayPresenter(
            cursorController,
            { [weak self] screen in
                guard let self = self else { return }
                self.performanceRecorder.mark(.firstInteraction, in: self.session)
                self.releaseOverlays()
                Task { @MainActor in
                    await self.onSelection(screen)
                }
            },
            { [weak self] in
                guard let self = self else { return }
                self.releaseOverlays()
                Task { @MainActor in
                    self.onCancel()
                }
            }
        )

        for overlay in overlayWindows {
            if let contentView = overlay.contentView {
                contentView.discardCursorRects()
                contentView.resetCursorRects()
                overlay.invalidateCursorRects(for: contentView)
            }
        }

        cursorController.handleCursorUpdate()
        cursorController.scheduleReprime()
        performanceRecorder.mark(.overlayVisible, in: session)
    }

    func dismiss() {
        releaseOverlays()
    }

    private func releaseOverlays() {
        for overlay in overlayWindows {
            overlay.onScreenSelected = nil
            overlay.onCancelled = nil
            overlay.close()
        }
        overlayWindows = []
        cursorSession?.end()
        cursorSession = nil
    }
}

extension FullscreenCaptureSessionCoordinator: FullscreenCaptureSessionHandling {}

@MainActor
final class WindowCaptureSessionCoordinator {
    enum SelectionResult {
        case selected(@MainActor () async throws -> CGImage)
        case cancelled
        case failedToStart
    }

    typealias PickerHandler = @MainActor (@escaping @MainActor () -> Void) async -> SelectionResult

    private let session: CapturePerformanceRecorder.Session
    private let performanceRecorder: CapturePerformanceRecorder
    private let hasWarmContent: Bool
    private let prewarmContent: @MainActor () async -> Void
    private let pickWindow: PickerHandler

    init(
        session: CapturePerformanceRecorder.Session,
        performanceRecorder: CapturePerformanceRecorder,
        hasWarmContent: Bool,
        prewarmContent: @escaping @MainActor () async -> Void,
        pickWindow: @escaping PickerHandler
    ) {
        self.session = session
        self.performanceRecorder = performanceRecorder
        self.hasWarmContent = hasWarmContent
        self.prewarmContent = prewarmContent
        self.pickWindow = pickWindow
    }

    func pick() async -> SelectionResult {
        // Do not NSApp.activate before SCContentSharingPicker — the picker is
        // system UI and activating Caloura steals focus from the target app,
        // which can invalidate the filter the picker returns. See CLAUDE.md.
        let wasWarm = hasWarmContent
        let prewarmStart = CFAbsoluteTimeGetCurrent()
        await runPrewarmWithTimeout()
        let prewarmMs = (CFAbsoluteTimeGetCurrent() - prewarmStart) * 1000.0
        performanceRecorder.recordDuration(
            .prewarmComplete,
            milliseconds: prewarmMs,
            in: session
        )
        return await pickWindow { [performanceRecorder, session] in
            performanceRecorder.mark(
                wasWarm ? .pickerVisibleWarm : .pickerVisibleCold,
                in: session
            )
        }
    }

    /// Run prewarm with a short hard cap. If shareable-content enumeration
    /// is slow or hangs, fall through to the picker cold rather than making
    /// the user wait. The system picker fetches fresh content on its own.
    /// `SCShareableContent.current` does not honor Swift Task cancellation,
    /// so race the prewarm against a sleeper via `withTimeout` — on timeout,
    /// the prewarm task is abandoned and the picker proceeds cold.
    private func runPrewarmWithTimeout() async {
        let prewarm = prewarmContent
        _ = try? await withTimeout(seconds: 3) { () -> Void? in
            await prewarm()
            return ()
        }
    }
}

extension WindowCaptureSessionCoordinator: WindowCaptureSessionHandling {}
