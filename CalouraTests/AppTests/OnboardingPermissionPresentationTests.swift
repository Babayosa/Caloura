import XCTest
@testable import Caloura

final class OnboardingPermissionPresentationTests: XCTestCase {

    func testDeniedPresentation() {
        let uiModel = PermissionUIModel(
            status: .denied,
            guidanceText: "Denied",
            shouldShowStaleRecordBanner: false,
            isAlertCooldownActive: false
        )
        let presentation = OnboardingPermissionPresentation.from(uiModel)

        XCTAssertEqual(presentation.detail, .notGranted)
        XCTAssertTrue(presentation.showsGrantButton)
        XCTAssertFalse(presentation.showsCheckAgainButton)
        XCTAssertFalse(presentation.shouldShowStaleRecordBanner)
        XCTAssertEqual(presentation.statusHeadline, "Screen Recording not granted yet")
        XCTAssertEqual(presentation.statusMessage, "Denied")
    }

    func testNeedsRelaunchPresentation() {
        let uiModel = PermissionUIModel(
            status: .needsRelaunch,
            guidanceText: "Restart",
            shouldShowStaleRecordBanner: false,
            isAlertCooldownActive: false
        )
        let presentation = OnboardingPermissionPresentation.from(uiModel)

        XCTAssertEqual(presentation.detail, .needsRelaunch)
        XCTAssertFalse(presentation.showsGrantButton)
        XCTAssertTrue(presentation.showsRepairButton)
        XCTAssertTrue(presentation.showsResetRelaunchButton)
        XCTAssertFalse(presentation.showsCheckAgainButton)
        XCTAssertEqual(presentation.statusHeadline, "One relaunch still needed")
        XCTAssertEqual(presentation.statusMessage, "Restart")
    }

    func testStaleRecordBannerVisibility() {
        let first = PermissionUIModel(
            status: .staleRecord,
            guidanceText: "Stale",
            shouldShowStaleRecordBanner: true,
            isAlertCooldownActive: false
        )
        let firstPresentation = OnboardingPermissionPresentation.from(first)
        XCTAssertEqual(firstPresentation.detail, .staleRecord)
        XCTAssertTrue(firstPresentation.shouldShowStaleRecordBanner)
        XCTAssertTrue(firstPresentation.showsRepairButton)
        XCTAssertTrue(firstPresentation.showsCheckAgainButton)
        XCTAssertEqual(firstPresentation.statusHeadline, "macOS trusts a different Caloura copy")
        XCTAssertEqual(firstPresentation.statusMessage, "Stale")

        let second = PermissionUIModel(
            status: .staleRecord,
            guidanceText: "Stale",
            shouldShowStaleRecordBanner: false,
            isAlertCooldownActive: false
        )
        let secondPresentation = OnboardingPermissionPresentation.from(second)
        XCTAssertEqual(secondPresentation.detail, .staleRecord)
        XCTAssertFalse(secondPresentation.shouldShowStaleRecordBanner)
    }
}
