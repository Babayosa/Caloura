import SwiftUI
import XCTest
@testable import Caloura

@MainActor
final class WindowPrivacyTests: XCTestCase {

    private func makeScreenshot() -> ProcessedScreenshot {
        let image = TestImageFactory.makeTestImage(width: 120, height: 80)
        return ProcessedScreenshot(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ),
            cgImage: image,
            context: CaptureContext(mode: .area)
        )
    }

    // MARK: - SingleWindowPresenter

    func testSingleWindowPresenterHonorsNonShareableConfig() throws {
        let presenter = SingleWindowPresenter<Text>()
        defer { presenter.close() }

        _ = presenter.show(
            config: .init(
                title: "Privacy Test",
                size: CGSize(width: 120, height: 80),
                sharingType: .none
            ),
            activateApp: false
        ) {
            Text("Privacy")
        }

        let window = try XCTUnwrap(presenter.window)
        XCTAssertEqual(window.sharingType, .none)
    }

    func testSingleWindowPresenterDefaultsToShareableWindow() throws {
        let presenter = SingleWindowPresenter<Text>()
        defer { presenter.close() }

        _ = presenter.show(
            config: .init(
                title: "Shareable Test",
                size: CGSize(width: 120, height: 80)
            ),
            activateApp: false
        ) {
            Text("Shareable")
        }

        let window = try XCTUnwrap(presenter.window)
        XCTAssertEqual(window.sharingType, .readOnly)
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

    // MARK: - Panels and overlays

    func testQuickAccessOverlayCreatesNonShareablePanel() throws {
        QuickAccessOverlay.shared.show(for: makeScreenshot())
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
        PinnedScreenshotManager.shared.pin(makeScreenshot())
        defer { PinnedScreenshotManager.shared.debugPanels.forEach { $0.close() } }

        let panel = try XCTUnwrap(PinnedScreenshotManager.shared.debugPanels.last)
        XCTAssertEqual(panel.sharingType, .none)
    }

    func testCaptureOverlayWindowIsNonShareable() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available")
        }
        let window = CaptureOverlayWindow(for: screen, cursorController: nil)
        XCTAssertEqual(window.sharingType, .none)
    }

    func testScreenSelectionOverlayWindowIsNonShareable() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available")
        }
        let window = ScreenSelectionOverlayWindow(for: screen, cursorController: nil)
        XCTAssertEqual(window.sharingType, .none)
    }

    #if DEBUG
    func testUITestHostWindowIsNonShareable() throws {
        let window = try XCTUnwrap(UITestHostWindowController.shared.window)
        XCTAssertEqual(window.sharingType, .none)
    }
    #endif

    // MARK: - Screenshot/PII windows route .none through WindowConfig

    func testHistoryWindowIsNonShareable() throws {
        let controller = HistoryWindowController()
        controller.show(appState: AppState.shared)
        defer { controller.debugWindow?.close() }

        let window = try XCTUnwrap(controller.debugWindow)
        XCTAssertEqual(window.sharingType, .none)
    }

    func testAnnotationWindowIsNonShareable() throws {
        let controller = AnnotationWindowController()
        controller.show(image: makeScreenshot().image) { _ in }
        defer { controller.debugWindow?.close() }

        let window = try XCTUnwrap(controller.debugWindow)
        XCTAssertEqual(window.sharingType, .none)
    }

    func testBeautifyPreviewWindowIsNonShareable() throws {
        BeautifyPreviewController.shared.show(screenshot: makeScreenshot())
        defer { BeautifyPreviewController.shared.close() }

        let window = try XCTUnwrap(BeautifyPreviewController.shared.debugWindow)
        XCTAssertEqual(window.sharingType, .none)
    }

    func testRedactionReviewWindowIsNonShareable() throws {
        RedactionReviewController.shared.show(screenshot: makeScreenshot(), detections: [])
        defer { RedactionReviewController.shared.close() }

        let window = try XCTUnwrap(RedactionReviewController.shared.debugWindow)
        XCTAssertEqual(window.sharingType, .none)
    }
}
