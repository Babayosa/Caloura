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

        cursorController.beginCrosshairSession()

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
        cursorController.endCrosshairSession()
        overlayWindows = []
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
        cursorController.beginCrosshairSession()
        overlayWindows = overlayPresenter(
            cursorController,
            { [weak self] screen in
                guard let self = self else { return }
                self.cursorController.endCrosshairSession()
                self.performanceRecorder.mark(.firstInteraction, in: self.session)
                self.overlayWindows = []
                Task { @MainActor in
                    await self.onSelection(screen)
                }
            },
            { [weak self] in
                guard let self = self else { return }
                self.cursorController.endCrosshairSession()
                self.overlayWindows = []
                Task { @MainActor in
                    self.onCancel()
                }
            }
        )
        cursorController.scheduleReprime()
        performanceRecorder.mark(.overlayVisible, in: session)
    }

    func dismiss() {
        for overlay in overlayWindows {
            overlay.onScreenSelected = nil
            overlay.onCancelled = nil
            overlay.close()
        }
        overlayWindows = []
        cursorController.endCrosshairSession()
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
    private let activateApplication: @MainActor () -> Void
    private let prewarmContent: @MainActor () async -> Void
    private let pickWindow: PickerHandler

    init(
        session: CapturePerformanceRecorder.Session,
        performanceRecorder: CapturePerformanceRecorder,
        hasWarmContent: Bool,
        activateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        },
        prewarmContent: @escaping @MainActor () async -> Void,
        pickWindow: @escaping PickerHandler
    ) {
        self.session = session
        self.performanceRecorder = performanceRecorder
        self.hasWarmContent = hasWarmContent
        self.activateApplication = activateApplication
        self.prewarmContent = prewarmContent
        self.pickWindow = pickWindow
    }

    func pick() async -> SelectionResult {
        activateApplication()
        performanceRecorder.mark(.appActivated, in: session)

        let wasWarm = hasWarmContent
        await prewarmContent()
        return await pickWindow { [performanceRecorder, session] in
            performanceRecorder.mark(
                wasWarm ? .pickerVisibleWarm : .pickerVisibleCold,
                in: session
            )
        }
    }
}

extension WindowCaptureSessionCoordinator: WindowCaptureSessionHandling {}
