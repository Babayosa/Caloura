import AppKit
@testable import Caloura

@MainActor
final class FakeAreaCaptureSession: AreaCaptureSessionHandling {
    var overlayWindows: [CaptureOverlayWindow] = []

    private let onSelection: AreaCaptureSessionCoordinator.SelectionHandler
    private let onCancel: AreaCaptureSessionCoordinator.CancelHandler
    private let onFirstInteraction: AreaCaptureSessionCoordinator.EventHandler?

    private(set) var presentCalls = 0
    private(set) var dismissCalls = 0
    private(set) var lastSuppressDimming = false
    private(set) var lastPresentedWindows: [CaptureOverlayWindow] = []
    private(set) var updateFrozenImagesCalls = 0

    init(
        onSelection: @escaping AreaCaptureSessionCoordinator.SelectionHandler,
        onCancel: @escaping AreaCaptureSessionCoordinator.CancelHandler,
        onFirstInteraction: AreaCaptureSessionCoordinator.EventHandler?
    ) {
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.onFirstInteraction = onFirstInteraction
    }

    func present(windows: [CaptureOverlayWindow], suppressDimming: Bool) {
        presentCalls += 1
        lastPresentedWindows = windows
        lastSuppressDimming = suppressDimming
    }

    func updateFrozenImages(_ images: [NSScreen: CGImage]) {
        updateFrozenImagesCalls += 1
    }

    func dismiss() {
        dismissCalls += 1
    }

    func triggerSelection(rect: CGRect, screen: NSScreen, frozenImage: CGImage?) async {
        await onSelection(rect, screen, frozenImage)
    }

    func triggerCancel() {
        onCancel()
    }

    func triggerFirstInteraction() {
        onFirstInteraction?()
    }
}

@MainActor
final class FakeFullscreenCaptureSession: FullscreenCaptureSessionHandling {
    var overlayWindows: [ScreenSelectionOverlayWindow] = []

    private let onSelection: FullscreenCaptureSessionCoordinator.SelectionHandler
    private let onCancel: FullscreenCaptureSessionCoordinator.CancelHandler

    private(set) var presentCalls = 0
    private(set) var dismissCalls = 0

    init(
        onSelection: @escaping FullscreenCaptureSessionCoordinator.SelectionHandler,
        onCancel: @escaping FullscreenCaptureSessionCoordinator.CancelHandler
    ) {
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    var simulatedOverlayCount = 1

    func present() {
        presentCalls += 1
        // Populate overlayWindows so the entrypoint's empty-screens guard
        // does not interpret a fake session as a "no active displays" abort.
        // simulatedOverlayCount = 0 lets a test exercise that abort path.
        if simulatedOverlayCount > 0, let screen = NSScreen.main ?? NSScreen.screens.first {
            overlayWindows = (0..<simulatedOverlayCount).map { _ in
                ScreenSelectionOverlayWindow(for: screen, cursorController: nil)
            }
        } else {
            overlayWindows = []
        }
    }

    func dismiss() {
        dismissCalls += 1
    }

    func triggerSelection(screen: NSScreen) async {
        await onSelection(screen)
    }

    func triggerCancel() {
        onCancel()
    }
}

@MainActor
final class FakeWindowCaptureSession: WindowCaptureSessionHandling {
    private let result: WindowCaptureSessionCoordinator.SelectionResult

    private(set) var pickCalls = 0

    init(result: WindowCaptureSessionCoordinator.SelectionResult) {
        self.result = result
    }

    func pick() async -> WindowCaptureSessionCoordinator.SelectionResult {
        pickCalls += 1
        return result
    }
}
