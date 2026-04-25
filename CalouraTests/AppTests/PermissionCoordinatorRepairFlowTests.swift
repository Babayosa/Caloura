import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorRepairFlowTests: XCTestCase {

    // MARK: - Cooldown query purity (regression guard)

    func testIsCooldownActiveHasNoSideEffect() async {
        // Regression guard: `isCooldownActive` used to clear
        // `permissionUIModel.isAlertCooldownActive` as a side effect when the
        // cooldown had elapsed. The timer (`scheduleCooldownReset`) and
        // `updateUIModel`'s full reassignment are now the single source of
        // truth — the query itself must remain pure.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var currentDate = Date(timeIntervalSince1970: 10_000)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("cooldown-purity") },
            statusMessageSink: { _ in },
            now: { currentDate }
        )

        await coordinator.handleCapturePermissionFailure()
        XCTAssertTrue(
            coordinator.permissionUIModel.isAlertCooldownActive,
            "Precondition: model flag should be set after first failure"
        )

        currentDate = currentDate.addingTimeInterval(120)
        let stillActive = coordinator.isCooldownActive(at: currentDate)

        XCTAssertFalse(stillActive, "Query should report cooldown expired")
        XCTAssertTrue(
            coordinator.permissionUIModel.isAlertCooldownActive,
            "Query must not mutate the model — reset is the timer's job"
        )
    }

    // MARK: - Auto-repair consent

    func testAutoRepairRelaunchWaitsForUserApproval() async {
        // `.confirmRepairRelaunch` is destructive (TCC reset + forced
        // relaunch). It is only reachable when passive=.denied AND the
        // live interactive check also fails — that combination is
        // genuine stuck state. CG-granted + transient SCK failure is a
        // transient condition and must not trigger the repair prompt.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var presentedStates: [ScreenCaptureManager.PermissionState] = []
        let identity = PermissionTestHelpers.makeIdentity("needs-repair")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            primeCheck: { .transientFailure },
            interactiveCheck: { .transientFailure },
            alertPresenter: { state in presentedStates.append(state) },
            alertRequestedRelaunch: { false },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 22_000) },
            repairSCKAccess: { .transientFailure },
            resetTCCEntry: {
                XCTFail("TCC reset must not run when the user declines")
                return true
            },
            relaunchApp: {
                XCTFail("Relaunch must not happen without user approval")
            }
        )

        await coordinator.handleCapturePermissionFailure()

        XCTAssertTrue(
            presentedStates.contains(.confirmRepairRelaunch),
            "The repair path must ask the user before resetting TCC"
        )
    }

    func testAutoRepairRelaunchProceedsAfterUserApproval() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("approved-repair")
        var tccResetCount = 0
        var relaunchCount = 0
        var approvalEmitted = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            primeCheck: { .transientFailure },
            interactiveCheck: { .transientFailure },
            alertPresenter: { state in
                if state == .confirmRepairRelaunch {
                    approvalEmitted = true
                }
            },
            alertRequestedRelaunch: { approvalEmitted },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 23_000) },
            repairSCKAccess: { .transientFailure },
            resetTCCEntry: {
                tccResetCount += 1
                return true
            },
            relaunchApp: { relaunchCount += 1 }
        )

        await coordinator.handleCapturePermissionFailure()

        XCTAssertEqual(tccResetCount, 1, "TCC reset should run exactly once after approval")
        XCTAssertEqual(relaunchCount, 1, "Relaunch should run exactly once after approval")
    }

    func testAutoRepairRelaunchFailedTCCResetDoesNotRemainRepairing() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("failed-reset-repair")
        var approvalEmitted = false
        var relaunchCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            primeCheck: { .transientFailure },
            interactiveCheck: { .transientFailure },
            alertPresenter: { state in
                if state == .confirmRepairRelaunch {
                    approvalEmitted = true
                }
            },
            alertRequestedRelaunch: { approvalEmitted },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 23_500) },
            repairSCKAccess: { .transientFailure },
            resetTCCEntry: { false },
            relaunchApp: { relaunchCount += 1 }
        )

        coordinator.armPendingCaptureResume(mode: .area)
        await coordinator.handleCapturePermissionFailure()

        XCTAssertEqual(coordinator.permissionUIModel.status, .needsRelaunch)
        XCTAssertEqual(relaunchCount, 0, "Relaunch must not run after a failed TCC reset")
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }

    // MARK: - Fix 3 regression: no repair on single transient capture failure

    func testSingleTransientCaptureFailureWhenCGGrantedDoesNotTriggerRepair() async {
        // CG granted + silent repair fails == transient SCK hiccup, not a
        // permission problem. The repair flow (modal alert + TCC reset)
        // must NOT fire — surface a non-blocking status instead.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("cg-granted-transient")
        var presentedStates: [ScreenCaptureManager.PermissionState] = []
        var tccResetCount = 0
        var relaunchCount = 0
        var statusMessage: String?

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            primeCheck: { .transientFailure },
            interactiveCheck: { .transientFailure },
            alertPresenter: { state in presentedStates.append(state) },
            alertRequestedRelaunch: { false },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { statusMessage = $0 },
            now: { Date(timeIntervalSince1970: 24_000) },
            repairSCKAccess: { .transientFailure },
            resetTCCEntry: {
                tccResetCount += 1
                return true
            },
            relaunchApp: { relaunchCount += 1 }
        )

        await coordinator.handleCapturePermissionFailure()

        XCTAssertFalse(
            presentedStates.contains(.confirmRepairRelaunch),
            "No repair prompt when CG says granted — that is a transient SCK state"
        )
        XCTAssertFalse(
            presentedStates.contains(.neverGranted),
            "No permission-denied alert when CG says granted"
        )
        XCTAssertEqual(tccResetCount, 0, "TCC must not be reset on a single transient failure")
        XCTAssertEqual(relaunchCount, 0, "No relaunch on a single transient failure")
        XCTAssertNotNil(statusMessage, "A soft status message must be surfaced")
    }
}
