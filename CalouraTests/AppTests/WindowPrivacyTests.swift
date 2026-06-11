import SwiftUI
import XCTest
@testable import Caloura

@MainActor
final class WindowPrivacyTests: XCTestCase {

    func testSingleWindowPresenterCreatesNonShareableWindow() throws {
        let presenter = SingleWindowPresenter<Text>()
        defer { presenter.close() }

        _ = presenter.show(
            config: .init(
                title: "Privacy Test",
                size: CGSize(width: 120, height: 80)
            ),
            activateApp: false
        ) {
            Text("Privacy")
        }

        let window = try XCTUnwrap(presenter.window)
        XCTAssertEqual(window.sharingType, .none)
    }

    func testSingleWindowPresenterActivatesOnlyWhenRequested() {
        var activationCount = 0
        let presenter = SingleWindowPresenter<Text> {
            activationCount += 1
        }
        defer { presenter.close() }

        _ = presenter.show(
            config: .init(
                title: "Activation Test",
                size: CGSize(width: 120, height: 80)
            ),
            activateApp: false
        ) {
            Text("Passive")
        }
        presenter.bringToFront(activateApp: false)

        XCTAssertEqual(activationCount, 0)

        presenter.bringToFront(activateApp: true)

        XCTAssertEqual(activationCount, 1)
    }

    func testSingleWindowPresenterActivatesExistingWindowOnlyWhenRequested() {
        var activationCount = 0
        let presenter = SingleWindowPresenter<Text> {
            activationCount += 1
        }
        defer { presenter.close() }
        let config = SingleWindowPresenter<Text>.WindowConfig(
            title: "Existing Activation Test",
            size: CGSize(width: 120, height: 80)
        )

        _ = presenter.show(config: config, activateApp: false) {
            Text("First")
        }
        _ = presenter.show(config: config, activateApp: false) {
            Text("Second")
        }

        XCTAssertEqual(activationCount, 0)

        _ = presenter.show(config: config, activateApp: true) {
            Text("Third")
        }

        XCTAssertEqual(activationCount, 1)
    }

    func testQuickAccessOverlayCreatesNonShareablePanel() throws {
        let image = TestImageFactory.makeTestImage(width: 120, height: 80)
        let screenshot = ProcessedScreenshot(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ),
            cgImage: image,
            context: CaptureContext(mode: .area)
        )

        QuickAccessOverlay.shared.show(for: screenshot)
        defer { QuickAccessOverlay.shared.dismiss() }

        let panel = try XCTUnwrap(QuickAccessOverlay.shared.debugPanel)
        XCTAssertEqual(panel.sharingType, .none)
    }

    func testCountdownOverlayCreatesNonShareablePanel() throws {
        CountdownOverlay.shared.show(seconds: 3, onCancel: {})
        defer { CountdownOverlay.shared.dismiss() }

        let panel = try XCTUnwrap(CountdownOverlay.shared.debugPanel)
        XCTAssertEqual(panel.sharingType, .none)
    }

    func testPinnedScreenshotWindowIsNonShareable() throws {
        let image = TestImageFactory.makeTestImage(width: 120, height: 80)
        let screenshot = ProcessedScreenshot(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ),
            cgImage: image,
            context: CaptureContext(mode: .area)
        )

        PinnedScreenshotManager.shared.pin(screenshot)
        defer { PinnedScreenshotManager.shared.debugPanels.forEach { $0.close() } }

        let panel = try XCTUnwrap(PinnedScreenshotManager.shared.debugPanels.last)
        XCTAssertEqual(panel.sharingType, .none)
    }
}
