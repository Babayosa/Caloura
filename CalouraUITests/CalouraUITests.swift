import XCTest

final class CalouraUITests: XCTestCase {
    private var app: XCUIApplication!
    private var areaOverlayButton: XCUIElement!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let setupState = MainActor.assumeIsolated {
            let app = XCUIApplication()
            app.launchEnvironment["CALOURA_UI_TEST_HOST"] = "1"
            app.launch()
            app.activate()

            let areaOverlayButton = app.buttons["Area Overlay"]
            XCTAssertTrue(areaOverlayButton.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["idle"].waitForExistence(timeout: 5), app.debugDescription)
            return (app, areaOverlayButton)
        }
        app = setupState.0
        areaOverlayButton = setupState.1
    }

    override func tearDownWithError() throws {
        areaOverlayButton = nil
        app = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testAreaOverlayButtonShowsAreaState() {
        areaOverlayButton.click()

        XCTAssertTrue(
            app.staticTexts["area-overlay-visible"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["Drag to select  ·  ESC to cancel"].exists)
    }

    @MainActor
    func testFullscreenOverlayButtonShowsFullscreenState() {
        app.buttons["Fullscreen Overlay"].click()

        XCTAssertTrue(
            app.staticTexts["fullscreen-overlay-visible"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["Click a display to capture  ·  ESC to cancel"].exists)
    }

    @MainActor
    func testWindowPickerButtonShowsPresentedState() {
        app.buttons["Window Picker"].click()

        XCTAssertTrue(
            app.staticTexts["window-picker-visible"].waitForExistence(timeout: 5),
            app.debugDescription
        )
    }

    @MainActor
    func testQuickAccessButtonShowsCompactOverlay() {
        app.buttons["Quick Access"].click()

        XCTAssertTrue(
            app.staticTexts["quick-access-visible"].waitForExistence(timeout: 5),
            app.debugDescription
        )
    }

    @MainActor
    func testPermissionRepairButtonShowsRepairState() {
        app.buttons["Permission Repair"].click()

        XCTAssertTrue(
            app.staticTexts["permission-repair-visible"].waitForExistence(timeout: 5),
            app.debugDescription
        )
    }
}
