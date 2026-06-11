import XCTest
@testable import Caloura

@MainActor
final class ScreenCaptureScreenshotTargetTests: XCTestCase {

    private struct StubApp: FreezeShareableApplication, Equatable {
        let processID: pid_t
        let bundleIdentifier: String
    }

    private struct StubDisplay: ScreenshotShareableDisplay, Equatable {
        let frame: CGRect
    }

    private let calouraBundleID = "com.caloura.app"

    private let mainDisplay = StubDisplay(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117)
    )
    private let sideDisplay = StubDisplay(
        frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440)
    )

    // Pins the stealth-audit finding: the live SCK screenshot path (area /
    // fullscreen fallback when no frozen image exists) must capture through a
    // content filter that excludes Caloura's own application, so the user's
    // screenshot never contains Caloura's windows.
    func testCalouraInShareableContent_targetExcludesCaloura() {
        let caloura = StubApp(
            processID: 999,
            bundleIdentifier: calouraBundleID
        )
        let apps = [
            StubApp(processID: 111, bundleIdentifier: "com.other.app"),
            caloura
        ]
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        let target = ScreenCaptureManager.selfExcludedScreenshotTarget(
            containing: rect,
            displays: [mainDisplay, sideDisplay],
            applications: apps,
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertEqual(
            target?.excludedApplications,
            [caloura],
            "Live screenshot capture must exclude Caloura's own application"
        )
        XCTAssertEqual(target?.display, mainDisplay)
    }

    func testFullscreenRectEqualToDisplayFrame_isContained() {
        let target = ScreenCaptureManager.selfExcludedScreenshotTarget(
            containing: sideDisplay.frame,
            displays: [mainDisplay, sideDisplay],
            applications: [
                StubApp(processID: 999, bundleIdentifier: calouraBundleID)
            ],
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertEqual(target?.display, sideDisplay)
    }

    func testRectOnSecondDisplay_picksContainingDisplay() {
        let rect = CGRect(x: 2000, y: 200, width: 300, height: 300)

        let target = ScreenCaptureManager.selfExcludedScreenshotTarget(
            containing: rect,
            displays: [mainDisplay, sideDisplay],
            applications: [
                StubApp(processID: 999, bundleIdentifier: calouraBundleID)
            ],
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertEqual(target?.display, sideDisplay)
    }

    // Capture success beats stealth: a rect spanning two displays has no
    // single-display filter, so the caller must fall back to the unfiltered
    // rect capture instead of failing.
    func testRectSpanningDisplays_returnsNilForUnfilteredFallback() {
        let rect = CGRect(x: 1600, y: 100, width: 400, height: 300)

        let target = ScreenCaptureManager.selfExcludedScreenshotTarget(
            containing: rect,
            displays: [mainDisplay, sideDisplay],
            applications: [
                StubApp(processID: 999, bundleIdentifier: calouraBundleID)
            ],
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertNil(
            target,
            "A rect spanning displays must fall back to the unfiltered capture, not fail"
        )
    }

    // First capture after launch: an agent app may not yet appear in
    // SCShareableContent.applications. With nothing to exclude, the legacy
    // unfiltered call keeps pixel output identical.
    func testCalouraMissingFromShareableContent_returnsNilForUnfilteredFallback() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        let target = ScreenCaptureManager.selfExcludedScreenshotTarget(
            containing: rect,
            displays: [mainDisplay],
            applications: [
                StubApp(processID: 111, bundleIdentifier: "com.other.app")
            ],
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertNil(
            target,
            "Without a self application to exclude, the unfiltered path must be used"
        )
    }

    // MARK: - Configuration geometry

    func testConfiguration_sourceRectIsRelativeToDisplayOrigin() {
        let rect = CGRect(x: 2000, y: 200, width: 300, height: 150)

        let configuration = ScreenCaptureManager
            .makeSelfExcludedScreenshotConfiguration(
                rect: rect,
                displayFrame: sideDisplay.frame,
                pointPixelScale: 2
            )

        XCTAssertEqual(
            configuration.sourceRect,
            CGRect(x: 272, y: 200, width: 300, height: 150)
        )
        XCTAssertEqual(configuration.width, 600)
        XCTAssertEqual(configuration.height, 300)
        XCTAssertFalse(configuration.showsCursor)
        XCTAssertTrue(configuration.shouldBeOpaque)
    }

    func testConfiguration_fullscreenRectHasZeroOriginSourceRect() {
        let configuration = ScreenCaptureManager
            .makeSelfExcludedScreenshotConfiguration(
                rect: mainDisplay.frame,
                displayFrame: mainDisplay.frame,
                pointPixelScale: 2
            )

        XCTAssertEqual(
            configuration.sourceRect,
            CGRect(origin: .zero, size: mainDisplay.frame.size)
        )
        XCTAssertEqual(configuration.width, 3456)
        XCTAssertEqual(configuration.height, 2234)
    }
}
