import Foundation

/// Why a blocking permission alert was suppressed. The raw value is the
/// `reason=` token in the `permission_alert_suppressed` log line.
enum PermissionAlertSuppressionReason: String, Equatable {
    case alertInFlight = "inflight"
    case cooldownActive = "cooldown"
}

/// One decision produced by `PermissionRecoveryPlanner`. Pure data — the
/// coordinator (and `ScreenCaptureManager` for the replayd settle) executes
/// the step; the planner never performs side effects itself.
enum PermissionRecoveryStep: Equatable {
    // Probes and repair
    /// Run the live interactive SCK check.
    case probeSCK
    /// Best-effort replayd restart (INVARIANT-7: never gates recovery).
    case restartReplayd
    /// Kickstart succeeded: wait for replayd to settle, then re-probe SCK.
    case probeSCKAfterReplaydSettle
    /// H6 fast-skip: kickstart exited non-zero immediately (SIP-blocked on
    /// Tahoe), so the settle wait would be pure latency — skip the probe.
    case skipReplaydProbe

    // Publications (terminal unless noted)
    case publishWorking(clearRequestSession: Bool, clearPendingResume: Bool)
    /// The identity is already live-validated this process: publish
    /// `.working` without re-recording the working identity.
    case publishWorkingAlreadyValidated
    case publishDenied
    case publishConfigurationFailed
    case publishExplicitFailureEndingRequest
    /// Not terminal: publish `.grantedNeedsValidation` and stay in the
    /// settings-return retry loop, optionally attempting the one
    /// best-effort repair allowed per flow.
    case publishGrantedNeedsValidationAndRetry(attemptRepair: Bool)

    // Capture-failure surfaced outcomes (non-blocking message paths)
    /// `.configurationFailed` is a build problem, never a denial or repair
    /// candidate (INVARIANT-10). `publishFirst` is false when the passive
    /// refresh already published the status.
    case surfaceConfigurationFailed(publishFirst: Bool)
    /// CG granted but repair did not resolve: pin the explicit-failure
    /// diagnosis and surface a non-blocking message — a single capture
    /// failure with CG granted is not strong enough evidence for a modal.
    case surfaceExplicitFailure
    case surfaceStatusWithoutAlert(reason: PermissionAlertSuppressionReason)
    /// User declined the destructive repair: surface the status and start
    /// the alert cooldown — never chain a second modal for the same failure.
    case surfaceStatusAfterDeclinedRepair

    // Alerts
    /// Corroboration failed but no destructive repair is warranted —
    /// continue to the blocking-alert decision.
    case escalateToBlockingAlert
    /// Ask for explicit consent before the destructive TCC reset + relaunch.
    case presentRepairRelaunchConfirmation
    case presentBlockingAlert(ScreenCaptureManager.PermissionState)
    /// INVARIANT-6: pending capture resume stays armed only because the
    /// user requested a relaunch from the alert.
    case keepPendingResumeForRelaunch
    case clearPendingResumeAfterAlert

    // Destructive recovery
    case performTCCResetAndRelaunch
    /// The relaunch is underway — report `.repairing` without publishing.
    case finishRepairing
    case relaunch
    /// TCC reset failed mid-auto-relaunch: clear the pending resume
    /// (INVARIANT-6) and pin the explicit failure.
    case abortAutoRelaunch
    /// Settings-return deadline expired with one auto-relaunch still
    /// available: re-arm resume, reset TCC, and relaunch.
    case autoRelaunchWithTCCReset

    // Flow control
    case fallBackToPassiveRefresh
    case pollForValidation
}

/// Pure decision table for the two recovery flows
/// (`handleCapturePermissionFailure` and `revalidateAfterSettingsReturn`).
/// Each function maps one decision point's evidence to the next
/// `PermissionRecoveryStep` — no side effects, no singletons, no async —
/// so every branch of the former 130-line flows is unit-testable in
/// isolation. The coordinator owns sequencing, timing, and effects.
enum PermissionRecoveryPlanner {

    // MARK: - Capture-failure flow

    /// First decision after the passive refresh that opens the flow.
    static func captureFailureStep(
        afterPassiveStatus status: ScreenRecordingState
    ) -> PermissionRecoveryStep {
        switch status {
        case .configurationFailed:
            return .surfaceConfigurationFailed(publishFirst: false)
        case .denied:
            // Corroborate with a live check before any destructive repair.
            return .probeSCK
        case .working, .grantedNeedsValidation, .needsRelaunch, .staleRecord, .repairing:
            // CG is granted in some form — attempt silent repair before
            // any alert (best-effort, INVARIANT-7).
            return .restartReplayd
        }
    }

    /// After the silent replayd repair on the CG-granted path.
    static func captureFailureStep(
        afterSilentRepair result: ScreenCaptureAccessProbeResult
    ) -> PermissionRecoveryStep {
        switch result {
        case .authorized:
            return .publishWorking(clearRequestSession: false, clearPendingResume: true)
        case .userDeclined, .configurationFailure, .transientFailure:
            return .surfaceExplicitFailure
        }
    }

    /// After the live corroboration on the CG-denied path.
    /// `.confirmRepairRelaunch` is destructive (TCC reset + forced
    /// relaunch): it requires passive=.denied AND a failing live check AND
    /// the relaunch cooldown clear AND no alert already on screen.
    static func captureFailureStep(
        afterCorroboration result: ScreenCaptureAccessProbeResult,
        canAutoRepairRelaunch: Bool,
        isShowingAlert: Bool
    ) -> PermissionRecoveryStep {
        switch result {
        case .authorized:
            return .publishWorking(clearRequestSession: true, clearPendingResume: false)
        case .configurationFailure:
            return .surfaceConfigurationFailed(publishFirst: true)
        case .transientFailure where canAutoRepairRelaunch && !isShowingAlert:
            return .presentRepairRelaunchConfirmation
        case .transientFailure, .userDeclined:
            return .escalateToBlockingAlert
        }
    }

    /// The generic blocking-alert decision once destructive repair is
    /// ruled out. An in-flight alert wins over the cooldown for the
    /// suppression log reason.
    static func captureFailureBlockingAlertStep(
        status: ScreenRecordingState,
        isShowingAlert: Bool,
        cooldownActive: Bool
    ) -> PermissionRecoveryStep {
        if isShowingAlert {
            return .surfaceStatusWithoutAlert(reason: .alertInFlight)
        }
        if cooldownActive {
            return .surfaceStatusWithoutAlert(reason: .cooldownActive)
        }
        return .presentBlockingAlert(alertState(for: status))
    }

    /// After the `.confirmRepairRelaunch` consent alert.
    static func captureFailureStep(
        afterRepairConfirmation approved: Bool
    ) -> PermissionRecoveryStep {
        approved ? .performTCCResetAndRelaunch : .surfaceStatusAfterDeclinedRepair
    }

    /// After the approved TCC reset + relaunch attempt.
    static func captureFailureStep(
        afterRepairRelaunch resetSucceeded: Bool
    ) -> PermissionRecoveryStep {
        resetSucceeded ? .finishRepairing : .publishExplicitFailureEndingRequest
    }

    /// After the generic blocking alert was dismissed (INVARIANT-6).
    static func captureFailureStep(
        afterBlockingAlert requestedRelaunch: Bool
    ) -> PermissionRecoveryStep {
        requestedRelaunch ? .keepPendingResumeForRelaunch : .clearPendingResumeAfterAlert
    }

    // MARK: - Settings-return flow

    /// Without a fresh grant-request session there is nothing to poll for —
    /// the 180s trust window (INVARIANT-1) is not open.
    static func settingsReturnEntryStep(
        hasFreshRequestSession: Bool
    ) -> PermissionRecoveryStep {
        hasFreshRequestSession ? .pollForValidation : .fallBackToPassiveRefresh
    }

    /// Each poll iteration: trust a live validation from this process
    /// before probing again (INVARIANT-1).
    static func settingsReturnPollStep(
        hasLiveValidatedIdentity: Bool
    ) -> PermissionRecoveryStep {
        hasLiveValidatedIdentity ? .publishWorkingAlreadyValidated : .probeSCK
    }

    /// After one SCK validation attempt inside the retry loop. At most one
    /// best-effort repair per flow, and only while CG reports granted.
    static func settingsReturnStep(
        afterValidation result: ScreenCaptureAccessProbeResult,
        cgGranted: Bool,
        attemptedRepair: Bool
    ) -> PermissionRecoveryStep {
        switch result {
        case .authorized:
            return .publishWorking(clearRequestSession: true, clearPendingResume: false)
        case .userDeclined:
            return .publishDenied
        case .configurationFailure:
            return .publishConfigurationFailed
        case .transientFailure:
            return .publishGrantedNeedsValidationAndRetry(
                attemptRepair: cgGranted && !attemptedRepair
            )
        }
    }

    /// After the in-loop replayd repair attempt.
    static func settingsReturnStep(
        afterRepair result: ScreenCaptureAccessProbeResult
    ) -> PermissionRecoveryStep {
        switch result {
        case .authorized:
            return .publishWorking(clearRequestSession: true, clearPendingResume: false)
        case .userDeclined:
            return .publishDenied
        case .configurationFailure:
            return .publishConfigurationFailed
        case .transientFailure:
            return .publishGrantedNeedsValidationAndRetry(attemptRepair: false)
        }
    }

    /// Once the polling deadline expires: one auto-relaunch per request
    /// session, otherwise pin the explicit failure.
    static func settingsReturnDeadlineStep(
        canAutoRelaunch: Bool
    ) -> PermissionRecoveryStep {
        canAutoRelaunch ? .autoRelaunchWithTCCReset : .publishExplicitFailureEndingRequest
    }

    /// After the auto-relaunch TCC reset.
    static func settingsReturnStep(
        afterAutoRelaunchTCCReset resetSucceeded: Bool
    ) -> PermissionRecoveryStep {
        resetSucceeded ? .relaunch : .abortAutoRelaunch
    }

    // MARK: - Replayd repair (executed by ScreenCaptureManager)

    /// H6 fast-skip: when the kickstart process exits non-zero immediately
    /// (SIP blocks it on Tahoe), skip the 500ms settle wait and the
    /// follow-up probe — the restart cannot have done anything. The repair
    /// stays best-effort either way (INVARIANT-7).
    static func replaydFollowUpStep(
        kickstartExitedNonZero: Bool
    ) -> PermissionRecoveryStep {
        kickstartExitedNonZero ? .skipReplaydProbe : .probeSCKAfterReplaydSettle
    }

    // MARK: - Alert mapping

    /// Which alert flavor a blocking alert presents for a given status.
    static func alertState(
        for status: ScreenRecordingState
    ) -> ScreenCaptureManager.PermissionState {
        switch status {
        case .denied:
            return .neverGranted
        case .staleRecord,
             .needsRelaunch,
             .grantedNeedsValidation,
             .working,
             .repairing,
             .configurationFailed:
            return .grantedButFailing
        }
    }
}
