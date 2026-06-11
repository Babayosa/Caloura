import Foundation

// The serialized flow cores: each acquires evidence, asks
// `PermissionRecoveryPlanner` for the next step, and executes it through
// the gated publication helpers in `PermissionCoordinator.swift`. All run
// inside `serializedValidation` (INVARIANT-3).
extension PermissionCoordinator {
    func runUserInitiatedValidationCore() async -> ScreenRecordingState {
        sckStateResetter()
        let identity = await identityProvider()
        let cgGranted = passiveCheck()
        let timestamp = now()
        logger.info("interactive_check_start cg_granted=\(cgGranted, privacy: .public)")

        guard cgGranted
            || store.shouldTrustLiveValidationWithoutCoreGraphics(at: timestamp) else {
            return publishDenied(identity, source: .serializedFlow)
        }

        let validationResult = await interactiveCheck()
        logger.info(
            "interactive_check_result result=\(String(describing: validationResult), privacy: .public)"
        )

        if validationResult == .authorized {
            return publishWorkingValidated(identity, source: .serializedFlow)
        }
        if validationResult == .configurationFailure {
            return publishStatus(.configurationFailed, identity: identity, source: .serializedFlow)
        }

        // SCK failed — attempt auto-repair via replayd restart (best-effort on Tahoe)
        _ = publishStatus(.repairing, identity: identity, source: .serializedFlow)
        logger.info("auto_repair_start best_effort=true")
        let repairResult = await repairSCKAccess()
        logger.info(
            "auto_repair_result result=\(String(describing: repairResult), privacy: .public)"
        )

        if repairResult == .authorized {
            return publishWorkingValidated(identity, source: .serializedFlow)
        }

        if repairResult == .userDeclined {
            return publishDenied(identity, clearPermissionRequest: true, source: .serializedFlow)
        }
        if repairResult == .configurationFailure {
            return publishStatus(.configurationFailed, identity: identity, source: .serializedFlow)
        }

        return publishExplicitFailure(for: identity, source: .serializedFlow)
    }

    func revalidateAfterSettingsReturnCore(
        timeoutSeconds: TimeInterval,
        pollIntervalNanoseconds: UInt64,
        sckRetryDelayNanoseconds: UInt64,
        maxSCKRetries: Int
    ) async -> ScreenRecordingState {
        sckStateResetter()
        let identity = await identityProvider()
        let startedAt = now()
        guard PermissionRecoveryPlanner.settingsReturnEntryStep(
            hasFreshRequestSession: store.activeRequestSession(now: startedAt) != nil
        ) == .pollForValidation else {
            // .fallBackToPassiveRefresh — no fresh grant attempt to poll for.
            return await refreshPassiveStatus(source: .serializedFlow)
        }

        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        var attemptedRepair = false

        while now() < deadline {
            if PermissionRecoveryPlanner.settingsReturnPollStep(
                hasLiveValidatedIdentity: store.isLiveValidatedIdentity(identity)
            ) == .publishWorkingAlreadyValidated {
                store.clearRequestSession()
                return publishStatus(.working, identity: identity, source: .serializedFlow)
            }

            let cgGranted = passiveCheck()
            logger.info("settings_return_poll cg_granted=\(cgGranted, privacy: .public)")

            for attempt in 1...maxSCKRetries {
                let validationResult = await interactiveCheck()
                let validationLog = "settings_return_validation attempt=\(attempt)"
                    + " cg_granted=\(cgGranted)"
                    + " result=\(String(describing: validationResult))"
                logger.info("\(validationLog, privacy: .public)")

                let step = PermissionRecoveryPlanner.settingsReturnStep(
                    afterValidation: validationResult,
                    cgGranted: cgGranted,
                    attemptedRepair: attemptedRepair
                )
                switch step {
                case .publishGrantedNeedsValidationAndRetry(let attemptRepair):
                    _ = publishStatus(.grantedNeedsValidation, identity: identity, source: .serializedFlow)
                    if attemptRepair {
                        attemptedRepair = true
                        if let outcome = await runSettingsReturnRepair(for: identity) {
                            return outcome
                        }
                    }
                default:
                    return executeSettingsReturnPublication(step, identity: identity)
                }

                if attempt < maxSCKRetries {
                    try? await Task.sleep(nanoseconds: sckRetryDelayNanoseconds)
                }
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return await finishSettingsReturnAfterDeadline(for: identity)
    }

    func handleCapturePermissionFailureCore() async -> ScreenRecordingState {
        sckStateResetter()
        let identity = await identityProvider()
        let status = await refreshPassiveStatus(source: .serializedFlow)

        let step = PermissionRecoveryPlanner.captureFailureStep(afterPassiveStatus: status)
        switch step {
        case .surfaceConfigurationFailed(let publishFirst):
            return surfaceConfigurationFailed(for: identity, publishFirst: publishFirst)
        case .restartReplayd:
            // CG is granted: attempt silent repair before showing any alert.
            // Repair is best-effort — on Tahoe, replayd restart may be blocked by SIP.
            return await runCaptureFailureSilentRepair(for: identity, status: status)
        case .probeSCK:
            // Passive status is .denied. Corroborate with a live interactive
            // check before firing the destructive repair flow: if it succeeds,
            // TCC is stale but SCK works and a relaunch would only disrupt.
            return await corroborateCaptureFailureDenial(for: identity, status: status)
        default:
            return unplannedRecoveryStep(step, returning: status)
        }
    }
}

// MARK: - Recovery step execution
// `PermissionRecoveryPlanner` decides; these helpers execute the steps.

private extension PermissionCoordinator {
    /// Shared terminal surface: consume the pending resume, emit the
    /// non-blocking message, refresh the cooldown flag.
    @discardableResult
    func surfaceNonBlockingStatus(_ status: ScreenRecordingState, cooldownActive: Bool) -> ScreenRecordingState {
        clearPendingCaptureResume()
        statusMessageSink(PermissionStatusCore.nonBlockingMessage(for: status))
        updateCooldownInModel(cooldownActive: cooldownActive)
        return status
    }

    /// `.configurationFailed` outcome: surface the non-blocking message
    /// without any repair or denial escalation (INVARIANT-10).
    func surfaceConfigurationFailed(for identity: PermissionIdentity, publishFirst: Bool) -> ScreenRecordingState {
        let status = publishFirst
            ? publishStatus(.configurationFailed, identity: identity, source: .serializedFlow)
            : .configurationFailed
        return surfaceNonBlockingStatus(status, cooldownActive: false)
    }

    func runCaptureFailureSilentRepair(
        for identity: PermissionIdentity,
        status: ScreenRecordingState
    ) async -> ScreenRecordingState {
        logger.info("silent_repair_attempt best_effort=true")
        let repairResult = await repairSCKAccess()
        let step = PermissionRecoveryPlanner.captureFailureStep(afterSilentRepair: repairResult)
        switch step {
        case .publishWorking(let clearRequestSession, clearPendingResume: true):
            logger.info("silent_repair_success — no alert needed")
            clearPendingCaptureResume()
            _ = publishWorkingValidated(identity, clearPermissionRequest: clearRequestSession, source: .serializedFlow)
            return .working
        case .surfaceExplicitFailure:
            // When CG says granted, a single capture failure is not strong
            // enough evidence of a real permission problem — surface a
            // non-blocking status instead of cascading into a modal alert
            // that greys the menu bar (destructive repair needs passive=
            // .denied AND a failing interactive check).
            logger.info("silent_repair_did_not_resolve — CG granted, treating as transient")
            let failureStatus = publishExplicitFailure(for: identity, source: .serializedFlow)
            return surfaceNonBlockingStatus(failureStatus, cooldownActive: false)
        default:
            return unplannedRecoveryStep(step, returning: status)
        }
    }

    func corroborateCaptureFailureDenial(
        for identity: PermissionIdentity,
        status: ScreenRecordingState
    ) async -> ScreenRecordingState {
        let interactiveResult = await interactiveCheck()
        logger.info("repair_gate_interactive result=\(String(describing: interactiveResult), privacy: .public)")
        let canRepairRelaunch = interactiveResult == .transientFailure
            && store.canAutoRepairRelaunch(now: now())
        if canRepairRelaunch, isShowingAlert {
            let statusDescription = String(describing: status)
            logger.info(
                "permission_alert_suppressed reason=inflight_repair status=\(statusDescription, privacy: .public)"
            )
        }

        let step = PermissionRecoveryPlanner.captureFailureStep(
            afterCorroboration: interactiveResult,
            canAutoRepairRelaunch: canRepairRelaunch,
            isShowingAlert: isShowingAlert
        )
        switch step {
        case .publishWorking(clearRequestSession: true, clearPendingResume: false):
            return publishWorkingValidated(identity, source: .serializedFlow)
        case .surfaceConfigurationFailed(let publishFirst):
            return surfaceConfigurationFailed(for: identity, publishFirst: publishFirst)
        case .presentRepairRelaunchConfirmation:
            return await confirmAndRunRepairRelaunch(for: identity, status: status)
        case .escalateToBlockingAlert:
            return await presentOrSuppressBlockingAlert(for: identity, status: status)
        default:
            return unplannedRecoveryStep(step, returning: status)
        }
    }

    func confirmAndRunRepairRelaunch(
        for identity: PermissionIdentity,
        status: ScreenRecordingState
    ) async -> ScreenRecordingState {
        store.markAutoRepairRelaunchAttempted(at: now())
        isShowingAlert = true
        // defer clears across cancellation — see CLAUDE.md "Stateful flags require recovery API + diagnostic log + defer-based clear".
        defer { isShowingAlert = false }
        await alertPresenter(.confirmRepairRelaunch)
        let followUp = PermissionRecoveryPlanner.captureFailureStep(afterRepairConfirmation: alertRequestedRelaunch())
        switch followUp {
        case .performTCCResetAndRelaunch:
            logger.info("user_approved_repair_relaunch — TCC reset + relaunch")
            let resetSucceeded = await performTCCResetAndRelaunch()
            let outcome = PermissionRecoveryPlanner.captureFailureStep(afterRepairRelaunch: resetSucceeded)
            switch outcome {
            case .finishRepairing:
                return .repairing
            case .publishExplicitFailureEndingRequest:
                return publishExplicitFailure(for: identity, clearPermissionRequest: true, source: .serializedFlow)
            default:
                return unplannedRecoveryStep(outcome, returning: status)
            }
        case .surfaceStatusAfterDeclinedRepair:
            // User declined the destructive repair. Do NOT fall through to a
            // second modal alert — that's two blocking prompts back-to-back
            // for the same failure. Cooldown + non-blocking status instead.
            logger.info("user_declined_repair_relaunch — surfacing status only")
            store.noteBlockingAlertShown(at: now())
            return surfaceNonBlockingStatus(status, cooldownActive: true)
        default:
            return unplannedRecoveryStep(followUp, returning: status)
        }
    }

    func presentOrSuppressBlockingAlert(
        for identity: PermissionIdentity,
        status: ScreenRecordingState
    ) async -> ScreenRecordingState {
        let timestamp = now()
        let step = PermissionRecoveryPlanner.captureFailureBlockingAlertStep(
            status: status,
            isShowingAlert: isShowingAlert,
            cooldownActive: isCooldownActive(at: timestamp)
        )
        switch step {
        case .surfaceStatusWithoutAlert(let reason):
            let suppressMsg = "permission_alert_suppressed reason=\(reason.rawValue)"
                + " status=\(String(describing: status))"
            logger.info("\(suppressMsg, privacy: .public)")
            return surfaceNonBlockingStatus(status, cooldownActive: true)
        case .presentBlockingAlert(let alertState):
            let alertMsg = "permission_alert_presenting"
                + " state=\(String(describing: alertState)) path=\(identity.executablePath)"
            logger.info("\(alertMsg, privacy: .public)")
            isShowingAlert = true
            defer { isShowingAlert = false }  // see comment on the prior defer
            await alertPresenter(alertState)
            let followUp = PermissionRecoveryPlanner.captureFailureStep(afterBlockingAlert: alertRequestedRelaunch())
            switch followUp {
            case .keepPendingResumeForRelaunch:
                pendingCaptureResumeRequiresRelaunch = true
            case .clearPendingResumeAfterAlert:
                clearPendingCaptureResume()
            default:
                _ = unplannedRecoveryStep(followUp, returning: status)
            }
            store.noteBlockingAlertShown(at: timestamp)
            updateCooldownInModel(cooldownActive: true)
            return status
        default:
            return unplannedRecoveryStep(step, returning: status)
        }
    }

    /// Terminal publications shared by the settings-return validation and
    /// repair decision points.
    func executeSettingsReturnPublication(
        _ step: PermissionRecoveryStep,
        identity: PermissionIdentity
    ) -> ScreenRecordingState {
        switch step {
        case .publishWorking(clearRequestSession: true, clearPendingResume: false):
            return publishWorkingValidated(identity, source: .serializedFlow)
        case .publishDenied:
            return publishDenied(identity, clearPermissionRequest: true, source: .serializedFlow)
        case .publishConfigurationFailed:
            return publishStatus(.configurationFailed, identity: identity, source: .serializedFlow)
        default:
            return unplannedRecoveryStep(step, returning: .grantedNeedsValidation)
        }
    }

    /// Runs the one best-effort in-loop repair. Returns the terminal
    /// status, or nil to stay in the retry loop.
    func runSettingsReturnRepair(for identity: PermissionIdentity) async -> ScreenRecordingState? {
        _ = publishStatus(.repairing, identity: identity, source: .serializedFlow)
        logger.info("settings_return_auto_repair_start best_effort=true")
        let repairResult = await repairSCKAccess()
        logger.info("settings_return_auto_repair_result result=\(String(describing: repairResult), privacy: .public)")

        let step = PermissionRecoveryPlanner.settingsReturnStep(afterRepair: repairResult)
        if case .publishGrantedNeedsValidationAndRetry(attemptRepair: false) = step {
            _ = publishStatus(.grantedNeedsValidation, identity: identity, source: .serializedFlow)
            return nil
        }
        return executeSettingsReturnPublication(step, identity: identity)
    }

    func finishSettingsReturnAfterDeadline(for identity: PermissionIdentity) async -> ScreenRecordingState {
        let deadlineStep = PermissionRecoveryPlanner.settingsReturnDeadlineStep(
            canAutoRelaunch: store.canAutoRelaunchAfterSettingsReturn(at: now())
        )
        switch deadlineStep {
        case .autoRelaunchWithTCCReset:
            if let pendingMode = store.pendingResumeMode() {
                armPendingCaptureResume(mode: pendingMode)
            }
            markAutoRelaunchIssued()
            _ = publishStatus(.repairing, identity: identity, source: .serializedFlow)
            logger.info("settings_return_auto_relaunch with TCC reset")
            let resetSucceeded = await resetTCCEntry()
            let followUp = PermissionRecoveryPlanner.settingsReturnStep(afterAutoRelaunchTCCReset: resetSucceeded)
            switch followUp {
            case .relaunch:
                relaunchApp()
                return .repairing
            case .abortAutoRelaunch:
                clearPendingCaptureResume()
                return publishExplicitFailure(for: identity, clearPermissionRequest: true, source: .serializedFlow)
            default:
                return unplannedRecoveryStep(followUp, returning: .repairing)
            }
        case .publishExplicitFailureEndingRequest:
            return publishExplicitFailure(for: identity, clearPermissionRequest: true, source: .serializedFlow)
        default:
            return unplannedRecoveryStep(deadlineStep, returning: .grantedNeedsValidation)
        }
    }

    /// Marks the active request session as having spent its one
    /// auto-relaunch, and arms the resume-after-relaunch flag (INVARIANT-6:
    /// pending resume survives only because a relaunch is underway).
    func markAutoRelaunchIssued() {
        guard store.requestSession != nil else {
            return
        }
        store.markRequestSessionAutoRelaunched()
        pendingCaptureResumeRequiresRelaunch = true
    }

    /// Planner-contract guard: each decision function returns a small, tested
    /// subset of `PermissionRecoveryStep`, so executors only handle the steps
    /// that decision can produce. Reaching this means planner and executor
    /// disagree — fail fast in debug; log and keep the caller's status in release.
    func unplannedRecoveryStep(
        _ step: PermissionRecoveryStep,
        returning status: ScreenRecordingState
    ) -> ScreenRecordingState {
        assertionFailure("Unplanned recovery step: \(step)")
        logger.error("unplanned_recovery_step step=\(String(describing: step), privacy: .public)")
        return status
    }
}
