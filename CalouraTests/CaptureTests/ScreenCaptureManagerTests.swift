@preconcurrency import ScreenCaptureKit
import XCTest
@testable import Caloura

final class ScreenCaptureManagerTests: XCTestCase {

    // Create a fresh instance for each test to avoid shared state.
    // ScreenCaptureManager.init() is internal (not private), so direct
    // instantiation is possible. We avoid .shared to prevent test pollution.
    private var sut: ScreenCaptureManager!

    override func setUp() {
        super.setUp()
        sut = MainActor.assumeIsolated { ScreenCaptureManager() }
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial state

    @MainActor
    func testSCKFailed_initiallyFalse() {
        XCTAssertFalse(sut.sckFailed, "sckFailed should be false on a fresh instance")
    }

    // MARK: - resetSCKState

    @MainActor
    func testResetSCKState_setsSckFailedToFalse() {
        sut.setSCKFailedForTesting(true)
        XCTAssertTrue(sut.sckFailed)

        sut.resetSCKState()

        XCTAssertFalse(
            sut.sckFailed,
            "resetSCKState should set sckFailed back to false"
        )
    }

    @MainActor
    func testResetSCKState_calledMultipleTimes_remainsFalse() {
        sut.setSCKFailedForTesting(true)

        sut.resetSCKState()
        sut.resetSCKState()
        sut.resetSCKState()

        XCTAssertFalse(
            sut.sckFailed,
            "Multiple resetSCKState calls should keep sckFailed false"
        )
    }

    @MainActor
    func testResetSCKState_whenAlreadyFalse_remainsFalse() {
        XCTAssertFalse(sut.sckFailed)

        sut.resetSCKState()

        XCTAssertFalse(
            sut.sckFailed,
            "resetSCKState on already-false state should remain false"
        )
    }

    // MARK: - captureArea rejects degenerate rects

    @MainActor
    func testCaptureArea_zeroWidthRect_throws() async {
        let rect = CGRect(x: 0, y: 0, width: 0, height: 100)

        do {
            _ = try await sut.captureArea(rect: rect)
            XCTFail("captureArea should throw for zero-width rect")
        } catch {
            guard case CaptureError.invalidRegion(let reason) = error else {
                XCTFail("Expected CaptureError.invalidRegion, got \(error)")
                return
            }
            XCTAssertEqual(reason, rect.debugDescription)
        }
    }

    @MainActor
    func testCaptureArea_zeroHeightRect_throws() async {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 0)

        do {
            _ = try await sut.captureArea(rect: rect)
            XCTFail("captureArea should throw for zero-height rect")
        } catch {
            guard case CaptureError.invalidRegion = error else {
                XCTFail("Expected CaptureError.invalidRegion, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testCaptureArea_zeroWidthAndHeight_throws() async {
        let rect = CGRect(x: 50, y: 50, width: 0, height: 0)

        do {
            _ = try await sut.captureArea(rect: rect)
            XCTFail("captureArea should throw for zero-size rect")
        } catch {
            guard case CaptureError.invalidRegion = error else {
                XCTFail("Expected CaptureError.invalidRegion, got \(error)")
                return
            }
        }
    }

    // MARK: - CaptureError descriptions

    @MainActor
    func testCaptureError_noPermission_hasDescription() {
        let error = CaptureError.noPermission
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription!.contains("Screen recording permission"),
            "noPermission error should mention screen recording permission"
        )
    }

    @MainActor
    func testCaptureError_noDisplay_hasDescription() {
        let error = CaptureError.noDisplay
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("display"))
    }

    @MainActor
    func testCaptureError_invalidRegion_hasDescription() {
        let error = CaptureError.invalidRegion(reason: "{{0, 0}, {0, 100}}")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("invalid"))
    }

    @MainActor
    func testCaptureError_noContent_hasDescription() {
        let error = CaptureError.noContent(source: "ScreenCaptureKit screenshot")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("did not produce an image"))
    }

    @MainActor
    func testCaptureError_windowUnavailable_hasDescription() {
        let error = CaptureError.windowUnavailable(reason: "window vanished")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Pick the window again"))
    }

    @MainActor
    func testCaptureError_configurationFailed_hasDescription() {
        let error = CaptureError.configurationFailed("missing entitlements")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("signed Caloura app"))
    }

    @MainActor
    func testCaptureError_timeout_hasDescription() {
        let error = CaptureError.timeout(operation: "Capture")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timed out"))
    }

    @MainActor
    func testCaptureError_captureFailed_preservesReasonInLogs() {
        let error = CaptureError.captureFailed("test reason")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription!.contains("Try again"),
            "captureFailed error should provide recovery guidance"
        )
        XCTAssertTrue(error.logMessage.contains("test reason"))
    }

    @MainActor
    func testCaptureError_cancelled_hasDescription() {
        let error = CaptureError.cancelled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("cancelled"))
    }

    // MARK: - display-space rect conversion

    @MainActor
    func testCaptureRectInDisplaySpace_mapsLocalSelectionToGlobalDisplaySpace() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let resolved = try sut.resolveScreen(screen)
        let displayBounds = CGDisplayBounds(resolved.displayID)
        let localRect = CGRect(x: 12, y: 24, width: 120, height: 80)

        let converted = try sut.captureRectInDisplaySpace(
            rect: localRect,
            screen: screen
        )

        let expected = CGRect(
            x: displayBounds.origin.x + localRect.origin.x,
            y: displayBounds.origin.y + (screen.frame.height - localRect.origin.y - localRect.height),
            width: localRect.width,
            height: localRect.height
        ).integral

        XCTAssertEqual(converted, expected)
    }

    @MainActor
    func testFullscreenRectInDisplaySpace_matchesDisplayBounds() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let resolved = try sut.resolveScreen(screen)

        let fullscreenRect = try sut.fullscreenRectInDisplaySpace(screen: screen)

        XCTAssertEqual(fullscreenRect, CGDisplayBounds(resolved.displayID).integral)
    }

    @MainActor
    func testMakeFreezeSnapshotConfiguration_usesNativeRetinaDimensions() throws {
        // The freeze snapshot is the backdrop behind the selection overlay,
        // so it must render at native pixel density. Downsampling and then
        // having the display layer upscale was producing visible blur on
        // Retina displays.
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let scale = screen.backingScaleFactor

        let configuration = sut.makeFreezeSnapshotConfiguration(for: screen)

        XCTAssertEqual(configuration.width, max(1, Int(ceil(screen.frame.width * scale))))
        XCTAssertEqual(configuration.height, max(1, Int(ceil(screen.frame.height * scale))))
        XCTAssertEqual(configuration.captureResolution, .best)
    }

    @MainActor
    func testMakeWindowCaptureConfiguration_zeroWidthThrowsWindowUnavailable() {
        do {
            _ = try sut.makeWindowCaptureConfiguration(
                contentRect: CGRect(x: 0, y: 0, width: 0, height: 120),
                pointPixelScale: 2
            )
            XCTFail("Expected zero-width window contentRect to fail")
        } catch let error as CaptureError {
            guard case .windowUnavailable = error else {
                return XCTFail("Expected windowUnavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected CaptureError.windowUnavailable, got \(error)")
        }
    }

    @MainActor
    func testMakeWindowCaptureConfiguration_nonFiniteScaleThrowsWindowUnavailable() {
        do {
            _ = try sut.makeWindowCaptureConfiguration(
                contentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
                pointPixelScale: .infinity
            )
            XCTFail("Expected non-finite pointPixelScale to fail")
        } catch let error as CaptureError {
            guard case .windowUnavailable = error else {
                return XCTFail("Expected windowUnavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected CaptureError.windowUnavailable, got \(error)")
        }
    }

    @MainActor
    func testCaptureWindow_usesInjectedFilteredScreenshotProvider() async throws {
        let expectedImage = TestImageFactory.makeTestImage(width: 160, height: 90)
        var capturedConfig: (width: Int, height: Int)?
        let manager = ScreenCaptureManager(
            filteredScreenshotProvider: { _, configuration in
                capturedConfig = (configuration.width, configuration.height)
                return expectedImage
            }
        )

        let image = try await manager.captureWindow(
            filter: SCContentFilter(),
            contentRect: CGRect(x: 20, y: 10, width: 80, height: 45),
            pointPixelScale: 2
        )

        XCTAssertEqual(image.width, expectedImage.width)
        XCTAssertEqual(capturedConfig?.width, 160)
        XCTAssertEqual(capturedConfig?.height, 90)
    }

    @MainActor
    func testCaptureFrozenDisplaySnapshotOperationCancelsUnderlyingCaptureOnTimeout() async {
        let captureStarted = expectation(description: "capture started")
        let captureCancelled = expectation(description: "capture cancelled")
        let operation = HangingFrozenDisplaySnapshotOperation(
            startedExpectation: captureStarted,
            cancelledExpectation: captureCancelled
        )
        let manager = ScreenCaptureManager(
            makeFrozenDisplaySnapshotOperation: { _, _, _ in
                operation
            }
        )

        do {
            _ = try await withTimeout(seconds: 0.01) {
                try await manager.captureFrozenDisplaySnapshot(
                    contentFilter: SCContentFilter(),
                    configuration: SCStreamConfiguration()
                )
            }
            XCTFail("Expected freeze snapshot timeout")
        } catch is TimeoutError {
            await fulfillment(of: [captureStarted, captureCancelled], timeout: 2.0)
            XCTAssertEqual(operation.cancelCount, 1)
        } catch {
            XCTFail("Expected TimeoutError, got \(error)")
        }
    }
}

@MainActor
private final class HangingFrozenDisplaySnapshotOperation: FrozenDisplaySnapshotOperation, @unchecked Sendable {
    private let startedExpectation: XCTestExpectation
    private let cancelledExpectation: XCTestExpectation
    private let releaseGate = AsyncGate()

    private(set) var cancelCount = 0

    init(
        startedExpectation: XCTestExpectation,
        cancelledExpectation: XCTestExpectation
    ) {
        self.startedExpectation = startedExpectation
        self.cancelledExpectation = cancelledExpectation
    }

    func captureImage() async throws -> CGImage {
        startedExpectation.fulfill()
        await releaseGate.wait()
        throw CancellationError()
    }

    func cancel() async {
        cancelCount += 1
        cancelledExpectation.fulfill()
        await releaseGate.open()
    }
}
