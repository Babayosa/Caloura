import XCTest
@testable import Caloura

@MainActor
final class URLSchemeHandlerTests: XCTestCase {

    // MARK: - URL Parsing

    func testHandle_captureAreaURL() {
        let url = URL(string: "caloura://capture/area")!
        // Should not crash; verifies parsing works
        URLSchemeHandler.handle(url)
    }

    func testHandle_captureFullscreenURL() {
        let url = URL(string: "caloura://capture/fullscreen")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_captureWindowURL() {
        let url = URL(string: "caloura://capture/window")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_captureRepeatURL() {
        let url = URL(string: "caloura://capture/repeat")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_captureDelayedURL() {
        let url = URL(string: "caloura://capture/delayed?seconds=3&mode=fullscreen")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_copyMarkdownURL() {
        let url = URL(string: "caloura://copy/markdown")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_copyCitationURL() {
        let url = URL(string: "caloura://copy/citation")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_copyOCRURL() {
        let url = URL(string: "caloura://copy/ocr")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_invalidSchemeIgnored() {
        let url = URL(string: "https://example.com")!
        // Should silently return without action
        URLSchemeHandler.handle(url)
    }

    func testHandle_unknownHostIgnored() {
        let url = URL(string: "caloura://nonexistent/path")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_presetNormalization() {
        // "lecture-notes" should normalize to "Lecture Notes"
        let url = URL(string: "caloura://capture/area?preset=lecture-notes")!
        URLSchemeHandler.handle(url)
        // Verify preset was set (if it matches a built-in name)
        XCTAssertEqual(AppSettings.shared.activePreset, "Lecture Notes")
    }

    func testHandle_unknownPresetIgnored() {
        let originalPreset = AppSettings.shared.activePreset
        let url = URL(string: "caloura://capture/area?preset=nonexistent-preset")!
        URLSchemeHandler.handle(url)
        // Should not change the active preset
        XCTAssertEqual(AppSettings.shared.activePreset, originalPreset)
    }
}
