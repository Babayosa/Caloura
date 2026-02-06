import Foundation
import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorTests: XCTestCase {

    func testRefreshPassiveStatusDeniedWhenCGNotGranted() {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { true },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("denied") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let status = coordinator.refreshPassiveStatus()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(coordinator.permissionUIModel.status, .denied)
    }

    func testMismatchDetectionAndBannerSuppression() {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("mismatch")
        defaults.set("different-fingerprint", forKey: "permissionLastWorkingIdentityFingerprint")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let firstStatus = coordinator.refreshPassiveStatus()
        XCTAssertEqual(firstStatus, .signatureMismatch)
        XCTAssertTrue(coordinator.permissionUIModel.shouldShowSignatureMismatchBanner)

        coordinator.markCurrentMismatchBannerShown()
        _ = coordinator.refreshPassiveStatus()
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowSignatureMismatchBanner)
    }

    func testCaptureFailureAlertIsDedupedByCooldown() {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var alertCount = 0
        var statusMessage = ""
        var now = Date(timeIntervalSince1970: 3_000)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { false },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("cooldown") },
            statusMessageSink: { statusMessage = $0 },
            now: { now }
        )

        coordinator.handleCapturePermissionFailure()
        coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 1)
        XCTAssertFalse(statusMessage.isEmpty)

        now = now.addingTimeInterval(50)
        coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 2)
    }

    func testUserInitiatedValidationTransitions() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var interactiveAuthorized = false

        let firstIdentity = PermissionTestHelpers.makeIdentity("primary")
        let firstCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { interactiveAuthorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { firstIdentity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_000) }
        )

        let firstStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(firstStatus, .grantedNeedsRelaunch)

        interactiveAuthorized = true
        let secondStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(secondStatus, .grantedWorking)

        let mismatchCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("secondary") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_100) }
        )

        let mismatchStatus = mismatchCoordinator.refreshPassiveStatus()
        XCTAssertEqual(mismatchStatus, .signatureMismatch)
    }
}
