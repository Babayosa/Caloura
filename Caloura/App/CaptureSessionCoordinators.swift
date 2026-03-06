import AppKit
import ScreenCaptureKit

@MainActor
protocol AreaCaptureSessionHandling: AnyObject {
    var overlayWindows: [CaptureOverlayWindow] { get }

    func present()
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

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        performanceRecorder.mark(.appActivated, in: session)

        overlayWindows = CaptureOverlayWindow.showOnAllScreens(
            cursorController: cursorController,
            onRegionSelected: { [weak self] rect, screen in
                guard let self = self else { return }
                self.cursorController.endCrosshairSession()
                self.overlayWindows = []
                Task { @MainActor in
                    await self.onSelection(rect, screen, self.frozenImages[screen])
                }
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                self.cursorController.endCrosshairSession()
                self.overlayWindows = []
                Task { @MainActor in
                    self.onCancel()
                }
            },
            onFirstMouseDown: { [weak self] in
                guard let self = self else { return }
                guard !self.firstInteractionRecorded else { return }
                self.firstInteractionRecorded = true
                self.performanceRecorder.mark(.firstInteraction, in: self.session)
                self.onFirstInteraction?()
            }
        )

        cursorController.beginCrosshairSession()
        performanceRecorder.mark(.overlayVisible, in: session)
    }

    func updateFrozenImages(_ images: [NSScreen: CGImage]) {
        frozenImages = images
        for overlay in overlayWindows {
            guard let screen = overlay.screen,
                  let image = images[screen] else {
                continue
            }
            overlay.frozenImage = image
        }
    }

    func dismiss() {
        for overlay in overlayWindows {
            overlay.onRegionSelected = nil
            overlay.onCancelled = nil
            overlay.onFirstMouseDown = nil
            overlay.close()
        }
        overlayWindows = []
        cursorController.endCrosshairSession()
    }
}

extension AreaCaptureSessionCoordinator: AreaCaptureSessionHandling {}

@MainActor
final class FullscreenCaptureSessionCoordinator {
    typealias SelectionHandler = @MainActor (NSScreen) async -> Void
    typealias CancelHandler = @MainActor () -> Void

    private let session: CapturePerformanceRecorder.Session
    private let performanceRecorder: CapturePerformanceRecorder
    private let cursorController: CaptureCursorControlling
    private let onSelection: SelectionHandler
    private let onCancel: CancelHandler

    private(set) var overlayWindows: [ScreenSelectionOverlayWindow] = []

    init(
        session: CapturePerformanceRecorder.Session,
        performanceRecorder: CapturePerformanceRecorder,
        cursorController: CaptureCursorControlling,
        onSelection: @escaping SelectionHandler,
        onCancel: @escaping CancelHandler
    ) {
        self.session = session
        self.performanceRecorder = performanceRecorder
        self.cursorController = cursorController
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        performanceRecorder.mark(.appActivated, in: session)

        overlayWindows = ScreenSelectionOverlayWindow.showOnAllScreens(
            cursorController: cursorController,
            onScreenSelected: { [weak self] screen in
                guard let self = self else { return }
                self.cursorController.endCrosshairSession()
                self.performanceRecorder.mark(.firstInteraction, in: self.session)
                self.overlayWindows = []
                Task { @MainActor in
                    await self.onSelection(screen)
                }
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                self.cursorController.endCrosshairSession()
                self.overlayWindows = []
                Task { @MainActor in
                    self.onCancel()
                }
            }
        )

        cursorController.beginCrosshairSession()
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
        NSApp.activate(ignoringOtherApps: true)
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
