import XCTest
@testable import Caloura

/// Decision-table tests for `PermissionRecoveryPlanner`. Every planner
/// function is enumerated over its full input space — the planner is pure,
/// so each cell is one assertion with no coordinator scaffolding.
final class PermissionRecoveryPlannerTests: XCTestCase {

    private let allProbeResults: [ScreenCaptureAccessProbeResult] = [
        .authorized, .userDeclined, .configurationFailure, .transientFailure
    ]

    private let allStatuses: [ScreenRecordingState] = [
        .denied, .grantedNeedsValidation, .working, .needsRelaunch,
        .staleRecord, .repairing, .configurationFailed
    ]

    // MARK: - Capture failure: after passive status

    func testCaptureFailureAfterPassiveStatusDeniedCorroboratesBeforeRepair() {
        // Destructive repair requires live corroboration, never the passive
        // signal alone — CGPreflight is advisory (INVARIANT-1).
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterPassiveStatus: .denied),
            .probeSCK
        )
    }

    func testCaptureFailureAfterPassiveStatusConfigurationFailedNeverRepairs() {
        // INVARIANT-10: missing entitlements is a build problem — never a
        // denial and never a repair candidate.
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterPassiveStatus: .configurationFailed),
            .surfaceConfigurationFailed(publishFirst: false)
        )
    }

    func testCaptureFailureAfterPassiveStatusCGGrantedAttemptsSilentRepair() {
        // INVARIANT-7: replayd restart is best-effort and precedes any alert.
        let cgGrantedStatuses: [ScreenRecordingState] = [
            .grantedNeedsValidation, .working, .needsRelaunch, .staleRecord, .repairing
        ]
        for status in cgGrantedStatuses {
            XCTAssertEqual(
                PermissionRecoveryPlanner.captureFailureStep(afterPassiveStatus: status),
                .restartReplayd,
                "Status \(status) should attempt silent repair before alerting"
            )
        }
    }

    // MARK: - Capture failure: after silent repair

    func testCaptureFailureAfterSilentRepairAuthorizedPublishesWorking() {
        // Silent repair keeps the request session open (the grant attempt
        // is still in flight) but consumes the pending resume.
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterSilentRepair: .authorized),
            .publishWorking(clearRequestSession: false, clearPendingResume: true)
        )
    }

    func testCaptureFailureAfterSilentRepairAnyFailureSurfacesNonBlocking() {
        // CG granted + one failed capture is not enough evidence for a
        // modal — every non-authorized repair outcome stays non-blocking.
        for result in allProbeResults where result != .authorized {
            XCTAssertEqual(
                PermissionRecoveryPlanner.captureFailureStep(afterSilentRepair: result),
                .surfaceExplicitFailure,
                "Repair result \(result) must surface a non-blocking status"
            )
        }
    }

    // MARK: - Capture failure: after corroboration

    func testCorroborationAuthorizedPublishesWorking() {
        for canRepair in [false, true] {
            for showing in [false, true] {
                XCTAssertEqual(
                    PermissionRecoveryPlanner.captureFailureStep(
                        afterCorroboration: .authorized,
                        canAutoRepairRelaunch: canRepair,
                        isShowingAlert: showing
                    ),
                    .publishWorking(clearRequestSession: true, clearPendingResume: false)
                )
            }
        }
    }

    func testCorroborationConfigurationFailureSurfacesConfiguration() {
        // INVARIANT-10 again: configuration failure short-circuits the
        // repair prompt even on the denied path.
        for canRepair in [false, true] {
            for showing in [false, true] {
                XCTAssertEqual(
                    PermissionRecoveryPlanner.captureFailureStep(
                        afterCorroboration: .configurationFailure,
                        canAutoRepairRelaunch: canRepair,
                        isShowingAlert: showing
                    ),
                    .surfaceConfigurationFailed(publishFirst: true)
                )
            }
        }
    }

    func testCorroborationTransientFailureGatesDestructiveRepair() {
        // The destructive TCC reset prompt fires only when the relaunch
        // cooldown is clear AND no alert is already on screen.
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(
                afterCorroboration: .transientFailure,
                canAutoRepairRelaunch: true,
                isShowingAlert: false
            ),
            .presentRepairRelaunchConfirmation
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(
                afterCorroboration: .transientFailure,
                canAutoRepairRelaunch: true,
                isShowingAlert: true
            ),
            .escalateToBlockingAlert
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(
                afterCorroboration: .transientFailure,
                canAutoRepairRelaunch: false,
                isShowingAlert: false
            ),
            .escalateToBlockingAlert
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(
                afterCorroboration: .transientFailure,
                canAutoRepairRelaunch: false,
                isShowingAlert: true
            ),
            .escalateToBlockingAlert
        )
    }

    func testCorroborationUserDeclinedEscalatesToBlockingAlert() {
        for canRepair in [false, true] {
            for showing in [false, true] {
                XCTAssertEqual(
                    PermissionRecoveryPlanner.captureFailureStep(
                        afterCorroboration: .userDeclined,
                        canAutoRepairRelaunch: canRepair,
                        isShowingAlert: showing
                    ),
                    .escalateToBlockingAlert
                )
            }
        }
    }

    // MARK: - Capture failure: blocking alert gate

    func testBlockingAlertSuppressedWhileAlertInFlight() {
        // An in-flight alert wins over the cooldown for the log reason.
        for cooldown in [false, true] {
            XCTAssertEqual(
                PermissionRecoveryPlanner.captureFailureBlockingAlertStep(
                    status: .denied,
                    isShowingAlert: true,
                    cooldownActive: cooldown
                ),
                .surfaceStatusWithoutAlert(reason: .alertInFlight)
            )
        }
    }

    func testBlockingAlertSuppressedDuringCooldown() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureBlockingAlertStep(
                status: .denied,
                isShowingAlert: false,
                cooldownActive: true
            ),
            .surfaceStatusWithoutAlert(reason: .cooldownActive)
        )
    }

    func testBlockingAlertPresentsWhenNotSuppressed() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureBlockingAlertStep(
                status: .denied,
                isShowingAlert: false,
                cooldownActive: false
            ),
            .presentBlockingAlert(.neverGranted)
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureBlockingAlertStep(
                status: .staleRecord,
                isShowingAlert: false,
                cooldownActive: false
            ),
            .presentBlockingAlert(.grantedButFailing)
        )
    }

    // MARK: - Capture failure: repair confirmation + relaunch

    func testRepairConfirmationApprovalRunsTCCResetDeclineSurfacesStatus() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterRepairConfirmation: true),
            .performTCCResetAndRelaunch
        )
        // Decline must not chain a second modal — cooldown + status only.
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterRepairConfirmation: false),
            .surfaceStatusAfterDeclinedRepair
        )
    }

    func testRepairRelaunchOutcome() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterRepairRelaunch: true),
            .finishRepairing
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterRepairRelaunch: false),
            .publishExplicitFailureEndingRequest
        )
    }

    func testBlockingAlertOutcomeArmsPendingResumeOnlyForRequestedRelaunch() {
        // INVARIANT-6: pending capture resume stays armed only when a
        // relaunch was actually requested; cleared on every other exit.
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterBlockingAlert: true),
            .keepPendingResumeForRelaunch
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.captureFailureStep(afterBlockingAlert: false),
            .clearPendingResumeAfterAlert
        )
    }

    // MARK: - Settings return: entry + poll

    func testSettingsReturnEntryRequiresFreshRequestSession() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnEntryStep(hasFreshRequestSession: true),
            .pollForValidation
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnEntryStep(hasFreshRequestSession: false),
            .fallBackToPassiveRefresh
        )
    }

    func testSettingsReturnPollTrustsLiveValidation() {
        // INVARIANT-1: during the request-session window, a live SCK
        // validation from this process beats any stale passive signal.
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnPollStep(hasLiveValidatedIdentity: true),
            .publishWorkingAlreadyValidated
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnPollStep(hasLiveValidatedIdentity: false),
            .probeSCK
        )
    }

    // MARK: - Settings return: after validation

    func testSettingsReturnAfterValidationTerminalResults() {
        for cgGranted in [false, true] {
            for attemptedRepair in [false, true] {
                XCTAssertEqual(
                    PermissionRecoveryPlanner.settingsReturnStep(
                        afterValidation: .authorized,
                        cgGranted: cgGranted,
                        attemptedRepair: attemptedRepair
                    ),
                    .publishWorking(clearRequestSession: true, clearPendingResume: false)
                )
                XCTAssertEqual(
                    PermissionRecoveryPlanner.settingsReturnStep(
                        afterValidation: .userDeclined,
                        cgGranted: cgGranted,
                        attemptedRepair: attemptedRepair
                    ),
                    .publishDenied
                )
                // INVARIANT-10: entitlement problems are terminal here too.
                XCTAssertEqual(
                    PermissionRecoveryPlanner.settingsReturnStep(
                        afterValidation: .configurationFailure,
                        cgGranted: cgGranted,
                        attemptedRepair: attemptedRepair
                    ),
                    .publishConfigurationFailed
                )
            }
        }
    }

    func testSettingsReturnAfterValidationTransientAllowsOneRepair() {
        // At most one best-effort repair per flow, and only while CG
        // reports granted (INVARIANT-7: repair never gates recovery).
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(
                afterValidation: .transientFailure,
                cgGranted: true,
                attemptedRepair: false
            ),
            .publishGrantedNeedsValidationAndRetry(attemptRepair: true)
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(
                afterValidation: .transientFailure,
                cgGranted: true,
                attemptedRepair: true
            ),
            .publishGrantedNeedsValidationAndRetry(attemptRepair: false)
        )
        for attemptedRepair in [false, true] {
            XCTAssertEqual(
                PermissionRecoveryPlanner.settingsReturnStep(
                    afterValidation: .transientFailure,
                    cgGranted: false,
                    attemptedRepair: attemptedRepair
                ),
                .publishGrantedNeedsValidationAndRetry(attemptRepair: false)
            )
        }
    }

    // MARK: - Settings return: after repair

    func testSettingsReturnAfterRepairMapsEveryProbeResult() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(afterRepair: .authorized),
            .publishWorking(clearRequestSession: true, clearPendingResume: false)
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(afterRepair: .userDeclined),
            .publishDenied
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(afterRepair: .configurationFailure),
            .publishConfigurationFailed
        )
        // A failed repair never aborts the flow (INVARIANT-7) — back to the
        // retry loop with the repair budget spent.
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(afterRepair: .transientFailure),
            .publishGrantedNeedsValidationAndRetry(attemptRepair: false)
        )
    }

    // MARK: - Settings return: deadline + auto-relaunch

    func testSettingsReturnDeadlineAllowsOneAutoRelaunchPerSession() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnDeadlineStep(canAutoRelaunch: true),
            .autoRelaunchWithTCCReset
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnDeadlineStep(canAutoRelaunch: false),
            .publishExplicitFailureEndingRequest
        )
    }

    func testSettingsReturnAutoRelaunchTCCResetOutcome() {
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(afterAutoRelaunchTCCReset: true),
            .relaunch
        )
        // INVARIANT-6: the aborted relaunch clears the pending resume.
        XCTAssertEqual(
            PermissionRecoveryPlanner.settingsReturnStep(afterAutoRelaunchTCCReset: false),
            .abortAutoRelaunch
        )
    }

    // MARK: - Replayd fast-skip (H6)

    func testReplaydFollowUpSkipsSettleWaitWhenKickstartExitsNonZero() {
        // H6 fast-skip: a kickstart that exits non-zero immediately (SIP-
        // blocked on Tahoe) did nothing — skip the settle wait and probe.
        // The repair stays best-effort either way (INVARIANT-7).
        XCTAssertEqual(
            PermissionRecoveryPlanner.replaydFollowUpStep(kickstartExitedNonZero: true),
            .skipReplaydProbe
        )
        XCTAssertEqual(
            PermissionRecoveryPlanner.replaydFollowUpStep(kickstartExitedNonZero: false),
            .probeSCKAfterReplaydSettle
        )
    }

    // MARK: - Alert mapping

    func testAlertStateMapsDeniedToNeverGrantedAndEverythingElseToFailing() {
        for status in allStatuses {
            let expected: ScreenCaptureManager.PermissionState =
                status == .denied ? .neverGranted : .grantedButFailing
            XCTAssertEqual(
                PermissionRecoveryPlanner.alertState(for: status),
                expected,
                "Alert mapping for \(status)"
            )
        }
    }
}
