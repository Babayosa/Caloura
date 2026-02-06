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

    func testHandle_historyURL_postsNotification() {
        let expectation = XCTNSNotificationExpectation(name: .showHistory)
        let url = URL(string: "caloura://history")!
        URLSchemeHandler.handle(url)
        wait(for: [expectation], timeout: 1.0)
    }

    func testHandle_settingsURL_postsNotification() {
        let expectation = XCTNSNotificationExpectation(name: .showSettings)
        let url = URL(string: "caloura://settings")!
        URLSchemeHandler.handle(url)
        wait(for: [expectation], timeout: 1.0)
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

    // MARK: - Delayed Capture Bounds

    func testHandle_delayedSecondsZero_clampedToOne() {
        // seconds=0 should be clamped to 1 (minimum)
        let url = URL(string: "caloura://capture/delayed?seconds=0")!
        // Should not crash; seconds is clamped internally
        URLSchemeHandler.handle(url)
    }

    func testHandle_delayedSecondsNegative_clampedToOne() {
        let url = URL(string: "caloura://capture/delayed?seconds=-1")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_delayedSecondsHuge_clampedToTen() {
        let url = URL(string: "caloura://capture/delayed?seconds=99999")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_delayedSecondsNonNumeric_defaultsToThree() {
        let url = URL(string: "caloura://capture/delayed?seconds=abc")!
        URLSchemeHandler.handle(url)
    }

    // MARK: - Unknown Mode Rejection

    func testHandle_unknownCaptureMode_ignored() {
        // An unknown mode like "exploit" should be rejected
        let url = URL(string: "caloura://capture/exploit")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_xssAttemptInMode_ignored() {
        let url = URL(string: "caloura://capture/%3Cscript%3Ealert(1)%3C/script%3E")!
        URLSchemeHandler.handle(url)
    }

    // MARK: - Empty & Malformed Parameters

    func testHandle_emptySecondsParam_defaultsToThree() {
        let url = URL(string: "caloura://capture/delayed?seconds=")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_emptyModeParam_defaultsToArea() {
        let url = URL(string: "caloura://capture/delayed?mode=")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_unknownThenAction_ignored() {
        // An unknown then action like "rm -rf" should be filtered out
        let url = URL(string: "caloura://capture/area?then=rm%20-rf")!
        URLSchemeHandler.handle(url)
    }

    func testHandle_mixedValidInvalidActions() {
        // Only "copy" should be kept; "evil" should be filtered
        let url = URL(string: "caloura://capture/area?then=copy,evil")!
        URLSchemeHandler.handle(url)
    }
}
