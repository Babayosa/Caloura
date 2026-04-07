import AppKit
@preconcurrency import ScreenCaptureKit
@testable import Caloura

@MainActor
final class FakeScreenCaptureManager: ScreenCaptureManaging {
    var hasWarmWindowShareableContent = false
    private(set) var prewarmCalls = 0
    private(set) var fullScreenCalls = 0
    private(set) var areaCalls = 0
    private(set) var rectInDisplaySpaceCalls = 0
    private(set) var frozenSnapshotCalls = 0
    private(set) var windowCalls = 0
    private(set) var displaySpaceAreaCalls = 0

    var prewarmHandler: @MainActor () async -> Void = { }
    var fullScreenHandler: @MainActor (NSScreen?) async throws -> CGImage = { _ in
        TestImageFactory.makeTestImage(width: 120, height: 90)
    }
    var areaHandler: @MainActor (CGRect, NSScreen?) async throws -> CGImage = { _, _ in
        TestImageFactory.makeTestImage(width: 110, height: 80)
    }
    var rectInDisplaySpaceHandler: @MainActor (CGRect, NSScreen?) throws -> CGRect = { rect, _ in
        rect
    }
    var frozenSnapshotHandler: @MainActor (NSScreen?) async throws -> CGImage = { _ in
        TestImageFactory.makeTestImage(width: 125, height: 95)
    }
    var windowHandler: @MainActor (SCContentFilter) async throws -> CGImage = { _ in
        TestImageFactory.makeTestImage(width: 140, height: 100)
    }
    var displaySpaceAreaHandler: @MainActor (CGRect) async throws -> CGImage = { _ in
        TestImageFactory.makeTestImage(width: 100, height: 70)
    }

    func prewarmWindowShareableContent() async {
        prewarmCalls += 1
        await prewarmHandler()
    }

    func captureFullScreen(screen: NSScreen?) async throws -> CGImage {
        fullScreenCalls += 1
        return try await fullScreenHandler(screen)
    }

    func captureArea(rect: CGRect, screen: NSScreen?) async throws -> CGImage {
        areaCalls += 1
        return try await areaHandler(rect, screen)
    }

    func captureRectInDisplaySpace(rect: CGRect, screen: NSScreen?) throws -> CGRect {
        rectInDisplaySpaceCalls += 1
        return try rectInDisplaySpaceHandler(rect, screen)
    }

    func captureFrozenDisplaySnapshot(screen: NSScreen?) async throws -> CGImage {
        frozenSnapshotCalls += 1
        return try await frozenSnapshotHandler(screen)
    }

    func captureWindow(filter: SCContentFilter) async throws -> CGImage {
        windowCalls += 1
        return try await windowHandler(filter)
    }

    func captureAreaInDisplaySpace(_ rect: CGRect) async throws -> CGImage {
        displaySpaceAreaCalls += 1
        return try await displaySpaceAreaHandler(rect)
    }
}
