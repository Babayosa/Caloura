import XCTest
@testable import Caloura

@MainActor
final class URLSchemeHandlerTests: XCTestCase {
    nonisolated(unsafe) private var originalActivePreset = ""
    nonisolated(unsafe) private var originalLastHandledDate: Date?
    nonisolated(unsafe) private var originalIsCapturing = false
    nonisolated(unsafe) private var originalCaptureRequestID: UUID?

    override nonisolated func setUp() {
        super.setUp()
        let snapshot = MainActor.assumeIsolated {
            (
                AppSettings.shared.activePreset,
                URLSchemeHandler.lastHandledDate,
                AppState.shared.isCapturing,
                AppState.shared.currentCaptureRequestID
            )
        }
        originalActivePreset = snapshot.0
        originalLastHandledDate = snapshot.1
        originalIsCapturing = snapshot.2
        originalCaptureRequestID = snapshot.3
        MainActor.assumeIsolated {
            URLSchemeHandler.resetThrottleForTesting()
            AppState.shared.isCapturing = false
            AppState.shared.currentCaptureRequestID = nil
        }
    }

    override nonisolated func tearDown() {
        let restoredActivePreset = originalActivePreset
        let restoredLastHandledDate = originalLastHandledDate
        let restoredIsCapturing = originalIsCapturing
        let restoredCaptureRequestID = originalCaptureRequestID
        MainActor.assumeIsolated {
            AppSettings.shared.activePreset = restoredActivePreset
            URLSchemeHandler.setLastHandledDateForTesting(restoredLastHandledDate)
            AppState.shared.isCapturing = restoredIsCapturing
            AppState.shared.currentCaptureRequestID = restoredCaptureRequestID
        }
        super.tearDown()
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    // MARK: - Copy URL Token Gating

    @MainActor
    func testHandle_copyURLWithoutToken_isRejected() {
        // Polling-attack vector: an external app spams `caloura://copy/ocr`
        // hoping to drain whatever the user just captured. Without the
        // per-launch token, no copy command must be dispatched.
        let unexpected = expectation(description: "copy must NOT dispatch")
        unexpected.isInverted = true
        let observerID = AppCommandRouter.shared.addHandler { command in
            switch command {
            case .copyLastImage, .copyLastAsMarkdown,
                 .copyLastWithCitation, .copyLastOCRText:
                unexpected.fulfill()
            default:
                break
            }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        URLSchemeHandler.handle(URL(string: "caloura://copy/ocr")!)
        wait(for: [unexpected], timeout: 0.5)
    }

    @MainActor
    func testHandle_copyURLWithWrongToken_isRejected() {
        let unexpected = expectation(description: "copy must NOT dispatch")
        unexpected.isInverted = true
        let observerID = AppCommandRouter.shared.addHandler { command in
            if case .copyLastOCRText = command { unexpected.fulfill() }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        let url = URL(string: "caloura://copy/ocr?token=not-a-real-token")!
        URLSchemeHandler.handle(url)
        wait(for: [unexpected], timeout: 0.5)
    }

    @MainActor
    func testHandle_copyURLWithValidToken_dispatchesCommand() {
        let token = URLSchemeHandler.currentCopyAuthorizationToken()
        XCTAssertFalse(token.isEmpty, "token must be generated at first access")

        let expected = expectation(description: "ocr copy dispatched")
        let observerID = AppCommandRouter.shared.addHandler { command in
            if case .copyLastOCRText = command { expected.fulfill() }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        let url = URL(string: "caloura://copy/ocr?token=\(token)")!
        URLSchemeHandler.handle(url)
        wait(for: [expected], timeout: 1.0)
    }

    @MainActor
    func testHandle_copyURLWithEmptyToken_isRejected() {
        let unexpected = expectation(description: "copy must NOT dispatch")
        unexpected.isInverted = true
        let observerID = AppCommandRouter.shared.addHandler { command in
            if case .copyLastAsMarkdown = command { unexpected.fulfill() }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        URLSchemeHandler.handle(URL(string: "caloura://copy/markdown?token=")!)
        wait(for: [unexpected], timeout: 0.5)
    }

    @MainActor
    func testHandle_captureThenWithoutTokenDoesNotDispatchPostCaptureAction() {
        let unexpected = expectation(description: "post-capture copy must NOT dispatch")
        unexpected.isInverted = true
        let observerID = AppCommandRouter.shared.addHandler { command in
            switch command {
            case .captureArea:
                AppState.shared.isCapturing = true
                AppState.shared.currentCaptureRequestID = UUID()
            case .copyLastImage:
                unexpected.fulfill()
            default:
                break
            }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        URLSchemeHandler.handle(URL(string: "caloura://capture/area?then=copy")!)
        if let requestID = AppState.shared.currentCaptureRequestID {
            NotificationCenter.default.post(
                name: .captureCompleted,
                object: nil,
                userInfo: [AppNotificationUserInfoKey.captureRequestID: requestID]
            )
        }

        wait(for: [unexpected], timeout: 0.5)
    }

    @MainActor
    func testHandle_captureThenWithTokenRunsOnlyForMatchingCaptureRequest() {
        let token = URLSchemeHandler.currentCopyAuthorizationToken()
        let mismatched = UUID()
        var acceptedRequestID: UUID?
        let expected = expectation(description: "matching post-capture copy dispatched")
        let observerID = AppCommandRouter.shared.addHandler { command in
            switch command {
            case .captureArea:
                let requestID = UUID()
                acceptedRequestID = requestID
                AppState.shared.isCapturing = true
                AppState.shared.currentCaptureRequestID = requestID
            case .copyLastImage:
                expected.fulfill()
            default:
                break
            }
        }
        defer { AppCommandRouter.shared.removeHandler(observerID) }

        URLSchemeHandler.handle(URL(string: "caloura://capture/area?then=copy&token=\(token)")!)
        NotificationCenter.default.post(
            name: .captureCompleted,
            object: nil,
            userInfo: [AppNotificationUserInfoKey.captureRequestID: mismatched]
        )
        if let acceptedRequestID {
            NotificationCenter.default.post(
                name: .captureCompleted,
                object: nil,
                userInfo: [AppNotificationUserInfoKey.captureRequestID: acceptedRequestID]
            )
        }

        wait(for: [expected], timeout: 1.0)
    }
}
