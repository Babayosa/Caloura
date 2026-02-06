import XCTest
@testable import Caloura

final class OnboardingPermissionPresentationTests: XCTestCase {

    func testDeniedPresentation() {
        let uiModel = PermissionUIModel(
            status: .denied,
            guidanceText: "Denied",
            shouldShowSignatureMismatchBanner: false,
            isAlertCooldownActive: false
        )
        let presentation = OnboardingPermissionPresentation.from(uiModel)

        XCTAssertEqual(presentation.detail, .notGranted)
        XCTAssertTrue(presentation.showsGrantButton)
        XCTAssertTrue(presentation.showsCheckAgainButton)
        XCTAssertFalse(presentation.shouldShowMismatchBanner)
        XCTAssertEqual(presentation.statusHeadline, "Permission not granted yet")
        XCTAssertEqual(presentation.statusMessage, "You can continue now and grant this anytime.")
    }

    func testGrantedNeedsRelaunchPresentation() {
        let uiModel = PermissionUIModel(
            status: .grantedNeedsRelaunch,
            guidanceText: "Restart",
            shouldShowSignatureMismatchBanner: false,
            isAlertCooldownActive: false
        )
        let presentation = OnboardingPermissionPresentation.from(uiModel)

        XCTAssertEqual(presentation.detail, .grantedNotWorking)
        XCTAssertFalse(presentation.showsGrantButton)
        XCTAssertTrue(presentation.showsCheckAgainButton)
        XCTAssertEqual(presentation.statusHeadline, "Permission granted")
        XCTAssertEqual(presentation.statusMessage, "Restart")
    }

    func testSignatureMismatchBannerVisibility() {
        let first = PermissionUIModel(
            status: .signatureMismatch,
            guidanceText: "Mismatch",
            shouldShowSignatureMismatchBanner: true,
            isAlertCooldownActive: false
        )
        let firstPresentation = OnboardingPermissionPresentation.from(first)
        XCTAssertEqual(firstPresentation.detail, .signatureMismatch)
        XCTAssertTrue(firstPresentation.shouldShowMismatchBanner)
        XCTAssertTrue(firstPresentation.showsGrantButton)
        XCTAssertEqual(firstPresentation.statusHeadline, "Permission tied to a different build")
        XCTAssertEqual(firstPresentation.statusMessage, "Mismatch")

        let second = PermissionUIModel(
            status: .signatureMismatch,
            guidanceText: "Mismatch",
            shouldShowSignatureMismatchBanner: false,
            isAlertCooldownActive: false
        )
        let secondPresentation = OnboardingPermissionPresentation.from(second)
        XCTAssertEqual(secondPresentation.detail, .signatureMismatch)
        XCTAssertFalse(secondPresentation.shouldShowMismatchBanner)
    }
}
