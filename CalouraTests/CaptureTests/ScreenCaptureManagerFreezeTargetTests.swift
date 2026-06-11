import XCTest
@testable import Caloura

@MainActor
final class ScreenCaptureManagerFreezeTargetTests: XCTestCase {

    private struct StubApp: FreezeShareableApplication, Equatable {
        let processID: pid_t
        let bundleIdentifier: String
    }

    private let calouraBundleID = "com.caloura.app"

    // Pins audit finding 2.4: on the first capture after launch the app may
    // not yet appear in SCShareableContent.applications. Throwing here makes
    // the freeze backdrop silently absent; the correct behavior is to fall
    // back to capturing without self-exclusion.
    func testCurrentAppMissing_fallsBackToNoExclusions() {
        let apps = [
            StubApp(processID: 111, bundleIdentifier: "com.other.app"),
            StubApp(processID: 222, bundleIdentifier: "com.another.app")
        ]

        let exclusions = ScreenCaptureManager.freezeExcludedApplications(
            in: apps,
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertTrue(
            exclusions.isEmpty,
            "Missing self in shareable applications must fall back to unfiltered capture, not fail the freeze snapshot"
        )
    }

    func testCurrentAppPresent_matchedByProcessID() {
        let current = StubApp(processID: 999, bundleIdentifier: "")
        let apps = [
            StubApp(processID: 111, bundleIdentifier: "com.other.app"),
            current
        ]

        let exclusions = ScreenCaptureManager.freezeExcludedApplications(
            in: apps,
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertEqual(exclusions, [current])
    }

    func testCurrentAppPresent_matchedByBundleIdentifier() {
        // Agent apps can be relaunched with a different pid than the one SCK
        // cached; bundle identifier is the second matching signal.
        let current = StubApp(processID: 555, bundleIdentifier: calouraBundleID)
        let apps = [
            StubApp(processID: 111, bundleIdentifier: "com.other.app"),
            current
        ]

        let exclusions = ScreenCaptureManager.freezeExcludedApplications(
            in: apps,
            currentProcessID: 999,
            currentBundleIdentifier: calouraBundleID
        )

        XCTAssertEqual(exclusions, [current])
    }

    func testNilBundleIdentifier_stillMatchesByProcessID() {
        let current = StubApp(processID: 999, bundleIdentifier: "com.whatever")
        let apps = [current]

        let exclusions = ScreenCaptureManager.freezeExcludedApplications(
            in: apps,
            currentProcessID: 999,
            currentBundleIdentifier: nil
        )

        XCTAssertEqual(exclusions, [current])
    }

    func testNilBundleIdentifier_doesNotMatchUnrelatedApps() {
        let apps = [StubApp(processID: 111, bundleIdentifier: "com.other.app")]

        let exclusions = ScreenCaptureManager.freezeExcludedApplications(
            in: apps,
            currentProcessID: 999,
            currentBundleIdentifier: nil
        )

        XCTAssertTrue(
            exclusions.isEmpty,
            "A nil bundle identifier must never match an arbitrary app"
        )
    }
}
