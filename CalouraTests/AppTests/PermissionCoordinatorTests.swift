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
            alertPresenter: { _ in  },
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
            alertPresenter: { _ in  },
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

    func testCaptureFailureAlertIsDedupedByCooldown() async {
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

        await coordinator.handleCapturePermissionFailure()
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 1)
        XCTAssertFalse(statusMessage.isEmpty)

        now = now.addingTimeInterval(50)
        await coordinator.handleCapturePermissionFailure()
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
            alertPresenter: { _ in  },
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
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("secondary") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_100) }
        )

        let mismatchStatus = mismatchCoordinator.refreshPassiveStatus()
        XCTAssertEqual(mismatchStatus, .signatureMismatch)
    }

    // MARK: - Auto-Repair Tests

    func testRunUserInitiatedValidation_autoRepairsViaReplayd() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("repair-ok")
        var repairCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },       // SCK fails initially
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_000) },
            repairSCKAccess: {
                repairCalled = true
                return true                     // repair succeeds
            }
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertTrue(repairCalled)
        XCTAssertEqual(status, .grantedWorking)
        XCTAssertEqual(coordinator.permissionUIModel.status, .grantedWorking)
    }

    func testRunUserInitiatedValidation_repairFails_needsRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("repair-fail")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_100) },
            repairSCKAccess: { false }          // repair fails
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(status, .grantedNeedsRelaunch)
    }

    func testHandleCapturePermissionFailure_silentRepair_noAlert() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("silent-repair")
        var alertCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },             // CG granted
            interactiveCheck: { false },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_000) },
            repairSCKAccess: { true }           // silent repair succeeds
        )

        await coordinator.handleCapturePermissionFailure()

        XCTAssertEqual(alertCount, 0, "Alert should not show when silent repair succeeds")
        XCTAssertEqual(coordinator.permissionUIModel.status, .grantedWorking)
    }

    func testPerformTCCResetAndRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var resetCalled = false
        var relaunchCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { true },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("tcc-reset") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 7_000) },
            resetTCCEntry: { resetCalled = true },
            relaunchApp: { relaunchCalled = true }
        )

        await coordinator.performTCCResetAndRelaunch()

        XCTAssertTrue(resetCalled, "resetTCCEntry should be called")
        XCTAssertTrue(relaunchCalled, "relaunchApp should be called")
    }
}
