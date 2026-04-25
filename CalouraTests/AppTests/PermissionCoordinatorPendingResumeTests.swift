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

        // Passive=.denied so the alert path is exercised. Set recent
        // auto-repair to force the confirmRepairRelaunch branch onto
        // cooldown and reach the regular alert below.
        defaults.set(
            Date(timeIntervalSince1970: 6_020),
            forKey: "permissionLastAutoRepairRelaunchAt"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
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

        // Passive=.denied + auto-repair on cooldown forces the flow into
        // the regular (non-repair) alert path where the user's restart
        // approval preserves the pending capture resume.
        defaults.set(
            Date(timeIntervalSince1970: 6_020),
            forKey: "permissionLastAutoRepairRelaunchAt"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
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

    func testSettingsReturnFailedTCCResetClearsPendingResumeAndDoesNotRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("pending-reset-failure")
        var relaunchCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_150) },
            resetTCCEntry: { false },
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

        XCTAssertEqual(status, .needsRelaunch)
        XCTAssertFalse(relaunchCalled)
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }

    func testSettingsReturnAutoRelaunchWithoutPendingCaptureDoesNotArmDefaultArea() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("pending-none")
        var relaunchCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_200) },
            relaunchApp: { relaunchCalled = true }
        )

        XCTAssertTrue(coordinator.requestPermissionFromSystem())

        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 0,
            pollIntervalNanoseconds: 1,
            sckRetryDelayNanoseconds: 1,
            maxSCKRetries: 1
        )

        XCTAssertEqual(status, .repairing)
        XCTAssertTrue(relaunchCalled)
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }

    func testPerformTCCResetFailureClearsPendingResumeAndDoesNotRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var relaunchCalled = false
        var statusMessage: String?

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("pending-reset-direct") },
            statusMessageSink: { statusMessage = $0 },
            now: { Date(timeIntervalSince1970: 6_250) },
            resetTCCEntry: { false },
            relaunchApp: { relaunchCalled = true }
        )

        coordinator.armPendingCaptureResume(mode: .fullscreen)
        let didRelaunch = await coordinator.performTCCResetAndRelaunch()

        XCTAssertFalse(didRelaunch)
        XCTAssertFalse(relaunchCalled)
        XCTAssertEqual(
            statusMessage,
            "Screen Recording reset failed. Restart Caloura and try again."
        )
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }
}
