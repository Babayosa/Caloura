import ScreenCaptureKit
import XCTest
@testable import Caloura

@MainActor
final class WindowPickerManagerTests: XCTestCase {

    func testInit_configuresSingleWindowPickerMode() {
        let picker = FakeWindowSharingPicker()

        _ = WindowPickerManager(picker: picker)

        XCTAssertEqual(picker.defaultConfiguration.allowedPickerModes, .singleWindow)
        XCTAssertEqual(
            picker.defaultConfiguration.excludedBundleIDs,
            [Bundle.main.bundleIdentifier ?? "com.caloura.app"]
        )
        XCTAssertEqual(picker.addCallCount, 0)
    }

    func testPickWindow_selectedResultResumesAndDeactivatesPicker() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let task = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        picker.emitSelected(filter: SCContentFilter())

        let result = await task.value

        guard case .selected = result else {
            return XCTFail("Expected selected result, got \(result)")
        }
        XCTAssertEqual(picker.presentCallCount, 1)
        XCTAssertEqual(picker.addCallCount, 1)
        XCTAssertEqual(picker.removeCallCount, 1)
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_cancelledResultResumesAndDeactivatesPicker() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let task = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        picker.emitCancel()

        let result = await task.value

        guard case .cancelled = result else {
            return XCTFail("Expected cancelled result, got \(result)")
        }
        XCTAssertEqual(picker.removeCallCount, 1)
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_failedToStartResumesAndDeactivatesPicker() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let task = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        picker.emitStartFailure(NSError(domain: "tests", code: 7))

        let result = await task.value

        guard case .failedToStart = result else {
            return XCTFail("Expected failedToStart result, got \(result)")
        }
        XCTAssertEqual(picker.removeCallCount, 1)
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_timeoutCancelsPendingSession() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .milliseconds(10))

        let result = await manager.pickWindow()

        guard case .cancelled = result else {
            return XCTFail("Expected cancelled result, got \(result)")
        }
        XCTAssertEqual(picker.removeCallCount, 1)
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_secondCallWhilePendingRejectsNewRequest() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let firstTask = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)

        let second = await manager.pickWindow()
        picker.emitCancel()
        let first = await firstTask.value

        guard case .failedToStart = second else {
            return XCTFail("Expected second result to be failedToStart, got \(second)")
        }
        guard case .cancelled = first else {
            return XCTFail("Expected first result to be cancelled, got \(first)")
        }
        XCTAssertEqual(picker.presentCallCount, 1)
    }

    func testPickWindow_staleCallbackFromRemovedObserverIsIgnored() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let firstTask = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        guard let staleObserver = picker.lastAddedObserver else {
            return XCTFail("Expected first picker observer")
        }
        picker.emitCancel(to: staleObserver)
        let first = await firstTask.value

        guard case .cancelled = first else {
            return XCTFail("Expected first result to be cancelled, got \(first)")
        }

        let secondTask = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        picker.emitSelected(filter: SCContentFilter(), to: staleObserver)
        try? await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(picker.removeCallCount, 1)
        XCTAssertTrue(picker.isActive)

        picker.emitCancel()
        let second = await secondTask.value

        guard case .cancelled = second else {
            return XCTFail("Expected second result to be cancelled, got \(second)")
        }
        XCTAssertEqual(picker.removeCallCount, 2)
    }

    func testCaptureSelectedWindow_usesStoredFilterAndClearsSelection() async throws {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))
        let captureManager = FakeScreenCaptureManager()
        let expectedImage = TestImageFactory.makeTestImage(width: 170, height: 110)
        captureManager.windowHandler = { _ in expectedImage }

        let task = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        picker.emitSelected(filter: SCContentFilter())

        let result = await task.value
        guard case .selected = result else {
            return XCTFail("Expected selected result, got \(result)")
        }

        let image = try await manager.captureSelectedWindow(using: captureManager)
        XCTAssertEqual(image.width, expectedImage.width)
        XCTAssertEqual(captureManager.windowCalls, 1)

        do {
            _ = try await manager.captureSelectedWindow(using: captureManager)
            XCTFail("Expected second captureSelectedWindow call to fail")
        } catch let error as CaptureError {
            guard case .windowUnavailable = error else {
                return XCTFail("Expected windowUnavailable, got \(error)")
            }
        }
    }

    private func waitForPendingPicker(_ picker: FakeWindowSharingPicker) async {
        await pollUntil(timeout: 1.0) {
            picker.presentCallCount > 0 && picker.isActive && picker.lastAddedObserver != nil
        }
    }
}

@MainActor
private final class FakeWindowSharingPicker: WindowSharingPicking {
    var isActive = false
    var defaultConfiguration = SCContentSharingPickerConfiguration()
    private(set) var addCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var presentCallCount = 0
    private(set) var lastAddedObserver: (any SCContentSharingPickerObserver)?
    private var activeObservers: [ObjectIdentifier: any SCContentSharingPickerObserver] = [:]

    func add(_ observer: any SCContentSharingPickerObserver) {
        addCallCount += 1
        activeObservers[ObjectIdentifier(observer as AnyObject)] = observer
        lastAddedObserver = observer
    }

    func remove(_ observer: any SCContentSharingPickerObserver) {
        removeCallCount += 1
        activeObservers.removeValue(forKey: ObjectIdentifier(observer as AnyObject))
    }

    func present(using style: SCShareableContentStyle) {
        presentCallCount += 1
    }

    func emitSelected(
        filter: SCContentFilter,
        to observer: (any SCContentSharingPickerObserver)? = nil
    ) {
        guard let observer = resolvedObserver(observer) else { return }
        observer.contentSharingPicker(
            SCContentSharingPicker.shared,
            didUpdateWith: filter,
            for: nil
        )
    }

    func emitCancel(to observer: (any SCContentSharingPickerObserver)? = nil) {
        guard let observer = resolvedObserver(observer) else { return }
        observer.contentSharingPicker(
            SCContentSharingPicker.shared,
            didCancelFor: nil
        )
    }

    func emitStartFailure(
        _ error: Error,
        to observer: (any SCContentSharingPickerObserver)? = nil
    ) {
        guard let observer = resolvedObserver(observer) else { return }
        observer.contentSharingPickerStartDidFailWithError(error)
    }

    private func resolvedObserver(
        _ observer: (any SCContentSharingPickerObserver)?
    ) -> (any SCContentSharingPickerObserver)? {
        if let observer {
            return observer
        }
        return lastAddedObserver.flatMap {
            activeObservers[ObjectIdentifier($0 as AnyObject)]
        }
    }
}
