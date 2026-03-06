import XCTest
@testable import Caloura

@MainActor
final class URLSchemeHandlerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset throttle state so each test can fire a URL scheme request
        // without being rejected by the rate limiter.
        URLSchemeHandler.lastHandledDate = nil
    }

    // MARK: - Parse: Capture Modes

    func testParse_captureArea() {
        let url = URL(string: "caloura://capture/area")!
        let result = URLSchemeHandler.parse(url)
        XCTAssertEqual(result, .capture(mode: "area", preset: nil, delay: nil, delayMode: nil, thenActions: []))
    }

    func testParse_captureFullscreen() {
        let url = URL(string: "caloura://capture/fullscreen")!
        let result = URLSchemeHandler.parse(url)
        XCTAssertEqual(result, .capture(mode: "fullscreen", preset: nil, delay: nil, delayMode: nil, thenActions: []))
    }

    func testParse_captureWindow() {
        let url = URL(string: "caloura://capture/window")!
        let result = URLSchemeHandler.parse(url)
        XCTAssertEqual(result, .capture(mode: "window", preset: nil, delay: nil, delayMode: nil, thenActions: []))
    }

    func testParse_captureRepeat() {
        let url = URL(string: "caloura://capture/repeat")!
        let result = URLSchemeHandler.parse(url)
        XCTAssertEqual(result, .capture(mode: "repeat", preset: nil, delay: nil, delayMode: nil, thenActions: []))
    }

    func testParse_captureDelayed() {
        let url = URL(string: "caloura://capture/delayed?seconds=3&mode=fullscreen")!
        let result = URLSchemeHandler.parse(url)
        let expected = URLSchemeHandler.ParsedAction.capture(
            mode: "delayed", preset: nil, delay: 3, delayMode: "fullscreen", thenActions: []
        )
        XCTAssertEqual(result, expected)
    }

    // MARK: - Parse: Copy Routes

    func testParse_copyMarkdown() {
        let url = URL(string: "caloura://copy/markdown")!
        XCTAssertEqual(URLSchemeHandler.parse(url), .copy(format: "markdown"))
    }

    func testParse_copyCitation() {
        let url = URL(string: "caloura://copy/citation")!
        XCTAssertEqual(URLSchemeHandler.parse(url), .copy(format: "citation"))
    }

    func testParse_copyOCR() {
        let url = URL(string: "caloura://copy/ocr")!
        XCTAssertEqual(URLSchemeHandler.parse(url), .copy(format: "ocr"))
    }

    // MARK: - Parse: UI Routes

    func testParse_history() {
        let url = URL(string: "caloura://history")!
        XCTAssertEqual(URLSchemeHandler.parse(url), .showHistory)
    }

    func testParse_settings() {
        let url = URL(string: "caloura://settings")!
        XCTAssertEqual(URLSchemeHandler.parse(url), .showSettings)
    }

    // MARK: - Handle: Command routing

    func testHandle_historyURL_dispatchesShowHistoryCommand() {
        let expectation = expectation(description: "show history command")
        let observerID = AppCommandRouter.shared.addHandler { command in
            if command == .showHistory {
                expectation.fulfill()
            }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        let url = URL(string: "caloura://history")!
        URLSchemeHandler.handle(url)
        wait(for: [expectation], timeout: 1.0)
    }

    func testHandle_settingsURL_dispatchesShowSettingsCommand() {
        let expectation = expectation(description: "show settings command")
        let observerID = AppCommandRouter.shared.addHandler { command in
            if command == .showSettings {
                expectation.fulfill()
            }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        let url = URL(string: "caloura://settings")!
        URLSchemeHandler.handle(url)
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Rejection / Invalid Input

    func testParse_invalidSchemeReturnsNil() {
        let url = URL(string: "https://example.com")!
        XCTAssertNil(URLSchemeHandler.parse(url))
    }

    func testParse_unknownHostReturnsNil() {
        let url = URL(string: "caloura://nonexistent/path")!
        XCTAssertNil(URLSchemeHandler.parse(url))
    }

    func testParse_unknownCaptureMode_returnsNil() {
        let url = URL(string: "caloura://capture/exploit")!
        XCTAssertNil(URLSchemeHandler.parse(url))
    }

    func testParse_xssAttemptInMode_returnsNil() {
        let url = URL(string: "caloura://capture/%3Cscript%3Ealert(1)%3C/script%3E")!
        XCTAssertNil(URLSchemeHandler.parse(url))
    }

    // MARK: - Preset Handling

    func testHandle_presetNormalization() {
        let url = URL(string: "caloura://capture/area?preset=lecture-notes")!
        URLSchemeHandler.handle(url)
        XCTAssertEqual(AppSettings.shared.activePreset, "Lecture Notes")
    }

    func testParse_unknownPresetReturnsNilPreset() {
        let url = URL(string: "caloura://capture/area?preset=nonexistent-preset")!
        if case .capture(_, let preset, _, _, _) = URLSchemeHandler.parse(url) {
            XCTAssertNil(preset)
        } else {
            XCTFail("Expected capture action")
        }
    }

    // MARK: - Delayed Capture Bounds

    func testParse_delayedSecondsZero_clampedToOne() {
        let url = URL(string: "caloura://capture/delayed?seconds=0")!
        if case .capture(_, _, let delay, _, _) = URLSchemeHandler.parse(url) {
            XCTAssertEqual(delay, 1)
        } else {
            XCTFail("Expected capture action")
        }
    }

    func testParse_delayedSecondsNegative_clampedToOne() {
        let url = URL(string: "caloura://capture/delayed?seconds=-1")!
        if case .capture(_, _, let delay, _, _) = URLSchemeHandler.parse(url) {
            XCTAssertEqual(delay, 1)
        } else {
            XCTFail("Expected capture action")
        }
    }

    func testParse_delayedSecondsHuge_clampedToTen() {
        let url = URL(string: "caloura://capture/delayed?seconds=99999")!
        if case .capture(_, _, let delay, _, _) = URLSchemeHandler.parse(url) {
            XCTAssertEqual(delay, 10)
        } else {
            XCTFail("Expected capture action")
        }
    }

    func testParse_delayedSecondsNonNumeric_defaultsToThree() {
        let url = URL(string: "caloura://capture/delayed?seconds=abc")!
        if case .capture(_, _, let delay, _, _) = URLSchemeHandler.parse(url) {
            XCTAssertEqual(delay, 3)
        } else {
            XCTFail("Expected capture action")
        }
    }

    // MARK: - Then Actions

    func testParse_thenActions_validFiltered() {
        let url = URL(string: "caloura://capture/area?then=copy,evil")!
        if case .capture(_, _, _, _, let actions) = URLSchemeHandler.parse(url) {
            XCTAssertEqual(actions, ["copy"])
        } else {
            XCTFail("Expected capture action")
        }
    }

    func testParse_thenActions_unknownRejected() {
        let url = URL(string: "caloura://capture/area?then=rm%20-rf")!
        if case .capture(_, _, _, _, let actions) = URLSchemeHandler.parse(url) {
            XCTAssertTrue(actions.isEmpty)
        } else {
            XCTFail("Expected capture action")
        }
    }

    // MARK: - Empty/Malformed Parameters

    func testParse_emptySecondsParam_defaultsToThree() {
        let url = URL(string: "caloura://capture/delayed?seconds=")!
        if case .capture(_, _, let delay, _, _) = URLSchemeHandler.parse(url) {
            XCTAssertEqual(delay, 3)
        } else {
            XCTFail("Expected capture action")
        }
    }

    func testParse_emptyModeParam_defaultsToArea() {
        let url = URL(string: "caloura://capture/delayed?mode=")!
        if case .capture(_, _, _, let delayMode, _) = URLSchemeHandler.parse(url) {
            XCTAssertEqual(delayMode, "area")
        } else {
            XCTFail("Expected capture action")
        }
    }
}
