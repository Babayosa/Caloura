import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorPendingResumeTests: XCTestCase {
    func testClearPendingCaptureResumeIfNoRelaunchPendingClearsPendingResume() {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("pending-clear") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_025) }
        )

        coordinator.armPendingCaptureResume(mode: .area)
        coordinator.clearPendingCaptureResumeIfNoRelaunchPending()

        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }

    func testHandleCapturePermissionFailureCancelClearsPendingResume() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("permission-cancel")

        // Set recent auto-repair relaunch so the auto-fix path is on cooldown
        // and the alert path is exercised instead.
        defaults.set(
            Date(timeIntervalSince1970: 6_020),
            forKey: "permissionLastAutoRepairRelaunchAt"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            alertRequestedRelaunch: { false },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_050) },
            repairSCKAccess: { .transientFailure }
        )

        coordinator.armPendingCaptureResume(mode: .area)
        await coordinator.handleCapturePermissionFailure()

        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }

    func testHandleCapturePermissionFailureRestartPreservesPendingResume() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("permission-restart")

        // Put auto-repair on cooldown so the alert path is exercised.
        defaults.set(
            Date(timeIntervalSince1970: 6_020),
            forKey: "permissionLastAutoRepairRelaunchAt"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            alertRequestedRelaunch: { true },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_075) },
            repairSCKAccess: { .transientFailure }
        )

        coordinator.armPendingCaptureResume(mode: .fullscreen)
        await coordinator.handleCapturePermissionFailure()

        XCTAssertEqual(coordinator.takePendingCaptureResumeIfFresh(), .fullscreen)
    }

    func testClearPendingCaptureResumeIfNoRelaunchPendingPreservesPendingResumeAfterAutoRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("pending-relaunch")
        var relaunchCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_100) },
            relaunchApp: { relaunchCalled = true }
        )

        coordinator.armPendingCaptureResume(mode: .window)
        XCTAssertTrue(coordinator.requestPermissionFromSystem())

        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 0,
            pollIntervalNanoseconds: 1,
            sckRetryDelayNanoseconds: 1,
            maxSCKRetries: 1
        )
        coordinator.clearPendingCaptureResumeIfNoRelaunchPending()

        XCTAssertEqual(status, .repairing)
        XCTAssertTrue(relaunchCalled)
        XCTAssertEqual(coordinator.takePendingCaptureResumeIfFresh(), .window)
    }
}
