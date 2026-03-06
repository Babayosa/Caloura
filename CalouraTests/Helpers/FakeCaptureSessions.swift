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
    private(set) var updateFrozenImagesCalls = 0
    private(set) var lastFrozenImages: [NSScreen: CGImage] = [:]

    init(
        onSelection: @escaping AreaCaptureSessionCoordinator.SelectionHandler,
        onCancel: @escaping AreaCaptureSessionCoordinator.CancelHandler,
        onFirstInteraction: AreaCaptureSessionCoordinator.EventHandler?
    ) {
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.onFirstInteraction = onFirstInteraction
    }

    func present() {
        presentCalls += 1
    }

    func updateFrozenImages(_ images: [NSScreen: CGImage]) {
        updateFrozenImagesCalls += 1
        lastFrozenImages = images
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

    func present() {
        presentCalls += 1
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
