import ScreenCaptureKit
import XCTest
@testable import Caloura

@MainActor
final class WindowPickerManagerTests: XCTestCase {

    func testInit_configuresSingleWindowPickerMode() {
        let picker = FakeWindowSharingPicker()

        _ = WindowPickerManager(picker: picker)

        XCTAssertEqual(picker.addCallCount, 1)
        XCTAssertEqual(picker.defaultConfiguration.allowedPickerModes, .singleWindow)
        XCTAssertEqual(
            picker.defaultConfiguration.excludedBundleIDs,
            [Bundle.main.bundleIdentifier ?? "com.caloura.app"]
        )
    }

    func testPickWindow_selectedResultResumesAndDeactivatesPicker() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let task = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        manager.contentSharingPicker(
            SCContentSharingPicker.shared,
            didUpdateWith: SCContentFilter(),
            for: nil
        )

        let result = await task.value

        guard case .selected = result else {
            return XCTFail("Expected selected result, got \(result)")
        }
        XCTAssertEqual(picker.presentCallCount, 1)
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_cancelledResultResumesAndDeactivatesPicker() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let task = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        manager.contentSharingPicker(SCContentSharingPicker.shared, didCancelFor: nil)

        let result = await task.value

        guard case .cancelled = result else {
            return XCTFail("Expected cancelled result, got \(result)")
        }
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_failedToStartResumesAndDeactivatesPicker() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let task = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        manager.contentSharingPickerStartDidFailWithError(NSError(domain: "tests", code: 7))

        let result = await task.value

        guard case .failedToStart = result else {
            return XCTFail("Expected failedToStart result, got \(result)")
        }
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_timeoutCancelsPendingSession() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .milliseconds(10))

        let result = await manager.pickWindow()

        guard case .cancelled = result else {
            return XCTFail("Expected cancelled result, got \(result)")
        }
        XCTAssertFalse(picker.isActive)
    }

    func testPickWindow_secondCallCancelsPreviousSession() async {
        let picker = FakeWindowSharingPicker()
        let manager = WindowPickerManager(picker: picker, timeout: .seconds(5))

        let firstTask = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)

        let secondTask = Task { await manager.pickWindow() }
        await waitForPendingPicker(picker)
        manager.contentSharingPicker(SCContentSharingPicker.shared, didCancelFor: nil)

        let first = await firstTask.value
        let second = await secondTask.value

        guard case .cancelled = first else {
            return XCTFail("Expected first result to be cancelled, got \(first)")
        }
        guard case .cancelled = second else {
            return XCTFail("Expected second result to be cancelled, got \(second)")
        }
        XCTAssertEqual(picker.presentCallCount, 2)
    }

    private func waitForPendingPicker(_ picker: FakeWindowSharingPicker) async {
        await pollUntil(timeout: 1.0) {
            picker.presentCallCount > 0 && picker.isActive
        }
    }
}

@MainActor
private final class FakeWindowSharingPicker: WindowSharingPicking {
    var isActive = false
    var defaultConfiguration = SCContentSharingPickerConfiguration()
    private(set) var addCallCount = 0
    private(set) var presentCallCount = 0

    func add(_ observer: any SCContentSharingPickerObserver) {
        addCallCount += 1
    }

    func present(using style: SCShareableContentStyle) {
        presentCallCount += 1
    }
}
