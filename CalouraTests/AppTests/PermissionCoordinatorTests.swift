import Foundation
import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorTests: XCTestCase {

    func testRefreshPassiveStatusDeniedWhenCGNotGranted() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("denied") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let status = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(coordinator.permissionUIModel.status, .denied)
    }

    func testPassiveMismatchStaysGrantedNeedsValidation() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("stale")
        defaults.set("different-fingerprint", forKey: "permissionLastWorkingIdentityFingerprint")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let firstStatus = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(firstStatus, .grantedNeedsValidation)
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
    }

    func testCaptureFailureAlertIsDedupedByCooldown() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var alertCount = 0
        var statusMessage = ""
        var currentDate = Date(timeIntervalSince1970: 3_000)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("cooldown") },
            statusMessageSink: { statusMessage = $0 },
            now: { currentDate }
        )

        await coordinator.handleCapturePermissionFailure()
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 1)
        XCTAssertFalse(statusMessage.isEmpty)

        currentDate = currentDate.addingTimeInterval(50)
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 2)
    }

    func testUserInitiatedValidationTransitions() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var interactiveResult: ScreenCaptureAccessProbeResult = .transientFailure

        let firstIdentity = PermissionTestHelpers.makeIdentity("primary")
        let firstCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { interactiveResult },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { firstIdentity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_000) }
        )

        let firstStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(firstStatus, .needsRelaunch)

        interactiveResult = .authorized
        let secondStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(secondStatus, .working)

        let staleCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("secondary") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_100) },
            repairSCKAccess: { .transientFailure }
        )

        let staleStatus = await staleCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(staleStatus, .staleRecord)
    }

    func testRunUserInitiatedValidationAutoRepairsViaReplayd() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("repair-ok")
        var repairCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_000) },
            repairSCKAccess: {
                repairCalled = true
                return .authorized
            }
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertTrue(repairCalled)
        XCTAssertEqual(status, .working)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
    }

    func testRunUserInitiatedValidationRepairFailsNeedsRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("repair-fail")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_100) },
            repairSCKAccess: { .transientFailure }
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(status, .needsRelaunch)
    }

    func testHandleCapturePermissionFailureSilentRepairNoAlert() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("silent-repair")
        var alertCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_000) },
            repairSCKAccess: { .authorized }
        )

        await coordinator.handleCapturePermissionFailure()

        XCTAssertEqual(alertCount, 0)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
    }

    func testRevalidateAfterSettingsReturnPollsUntilGrantAppears() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("return")
        var passiveChecks = 0
        var interactiveChecks = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: {
                passiveChecks += 1
                return passiveChecks >= 2
            },
            interactiveCheck: {
                interactiveChecks += 1
                return .authorized
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 7_000 + Double(passiveChecks)) }
        )

        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 3,
            pollIntervalNanoseconds: 1_000_000
        )

        XCTAssertEqual(status, .working)
        XCTAssertGreaterThanOrEqual(passiveChecks, 2)
        XCTAssertEqual(interactiveChecks, 1)
    }

    func testPerformTCCResetAndRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var resetCalled = false
        var relaunchCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("tcc-reset") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 8_000) },
            resetTCCEntry: { resetCalled = true },
            relaunchApp: { relaunchCalled = true }
        )

        await coordinator.performTCCResetAndRelaunch()

        XCTAssertTrue(resetCalled)
        XCTAssertTrue(relaunchCalled)
    }

    func testPrimeIfPermissionGrantedCachesWorkingWithoutRepairUI() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("primed")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            primeCheck: { .authorized },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 9_000) }
        )

        let status = await coordinator.primeIfPermissionGranted()

        XCTAssertEqual(status, .working)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
    }
}
