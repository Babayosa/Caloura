import Foundation
import Observation
import os.log

/// Where a publication originated. `.serializedFlow` writes come from inside
/// a `serializedValidation` operation and always apply. `.passive` writes
/// (passive refresh, prime, cooldown timer) are deferred while a serialized
/// flow is in flight so they cannot overwrite in-progress flow state such as
/// `.repairing` (INVARIANT-3).
private enum PublicationSource {
    case passive
    case serializedFlow
}

/// What a publication wants to write: a full status/UI-model candidate, or
/// just the alert-cooldown flag.
private enum PublicationCandidate {
    case model(status: ScreenRecordingState, identity: PermissionIdentity)
    case alertCooldown(isActive: Bool)
}

/// Latest passive evidence observed while a serialized flow held the
/// publication gate. Coalesced (last write wins) and re-evaluated against
/// fresh store state when the flow completes, so the post-flow publication
/// reflects both the newest CG signal and the flow's outcome (diagnosis,
/// live validation).
private struct DeferredPassiveEvidence {
    let identity: PermissionIdentity
    let cgGranted: Bool
}

@Observable @MainActor
final class PermissionCoordinator {
    static let shared = PermissionCoordinator()

    typealias PassiveCheck = () -> Bool
    typealias PrimeCheck = () async -> ScreenCaptureAccessProbeResult
    typealias InteractiveCheck = () async -> ScreenCaptureAccessProbeResult
    typealias AlertPresenter = @MainActor @Sendable (ScreenCaptureManager.PermissionState) async -> Void
    typealias AlertRelaunchRequested = @MainActor @Sendable () -> Bool
    typealias PermissionRequester = () -> Bool
    typealias IdentityProvider = () async -> PermissionIdentity
    typealias StatusMessageSink = (String) -> Void
    typealias NowProvider = () -> Date
    typealias RepairCheck = () async -> ScreenCaptureAccessProbeResult
    typealias TCCReset = () async -> Bool
    typealias Relauncher = () -> Void
    typealias SCKStateResetter = () -> Void

    private(set) var permissionUIModel = PermissionUIModel()

    private let store: PermissionStore
    private let passiveCheck: PassiveCheck
    private let primeCheck: PrimeCheck
    private let interactiveCheck: InteractiveCheck
    private let alertPresenter: AlertPresenter
    private let alertRequestedRelaunch: AlertRelaunchRequested
    private let permissionRequester: PermissionRequester
    private let identityProvider: IdentityProvider
    private let statusMessageSink: StatusMessageSink
    private let now: NowProvider
    private let repairSCKAccess: RepairCheck
    private let resetTCCEntry: TCCReset
    private let relaunchApp: Relauncher
    private let sckStateResetter: SCKStateResetter
    private let logger = Logger(subsystem: "com.caloura.app", category: "Permission")

    private var inFlightValidation: Task<ScreenRecordingState, Never>?
    private var deferredPassiveEvidence: DeferredPassiveEvidence?
    private var hasDeferredCooldownRefresh = false
    private var isShowingAlert = false
    private let pendingCaptureResumeTTLSeconds: TimeInterval = 120
    private var cooldownResetTask: Task<Void, Never>?
    private var pendingCaptureResumeRequiresRelaunch = false

    @MainActor
    private final class AlertDecisionBox {
        var lastAction: ScreenCapturePermissionAlertAction = .cancel
    }

    init(defaults: UserDefaults = .standard) {
        let alertDecision = AlertDecisionBox()
        self.store = PermissionStore(defaults: defaults)
        self.passiveCheck = { ScreenCaptureManager.shared.passivePermissionGranted() }
        self.primeCheck = { await ScreenCaptureManager.shared.primeSCKAccessIfPossible() }
        self.interactiveCheck = { await ScreenCaptureManager.shared.validateSCKAccessUserInitiated() }
        self.alertPresenter = { state in
            alertDecision.lastAction = await ScreenCaptureManager.shared.showPermissionAlert(for: state)
        }
        self.alertRequestedRelaunch = {
            alertDecision.lastAction == .restartApp
        }
        self.permissionRequester = { ScreenCaptureManager.shared.requestPermission() }
        self.identityProvider = { await PermissionIdentityProvider.shared.currentIdentity() }
        self.statusMessageSink = { StatusMessageRouter.sink($0) }
        self.now = Date.init
        self.repairSCKAccess = { await ScreenCaptureManager.shared.repairSCKAccess() }
        self.resetTCCEntry = { await ScreenCaptureManager.shared.resetTCCEntry() }
        self.relaunchApp = { ScreenCaptureManager.shared.relaunchApp() }
        self.sckStateResetter = { ScreenCaptureManager.shared.resetSCKState() }
    }

    init(
        defaults: UserDefaults,
        passiveCheck: @escaping PassiveCheck,
        primeCheck: @escaping PrimeCheck = { .transientFailure },
        interactiveCheck: @escaping InteractiveCheck,
        alertPresenter: @escaping AlertPresenter,
        alertRequestedRelaunch: @escaping AlertRelaunchRequested = { false },
        permissionRequester: @escaping PermissionRequester,
        identityProvider: @escaping IdentityProvider,
        statusMessageSink: @escaping StatusMessageSink,
        now: @escaping NowProvider,
        repairSCKAccess: @escaping RepairCheck = { .transientFailure },
        resetTCCEntry: @escaping TCCReset = { true },
        relaunchApp: @escaping Relauncher = { },
        sckStateResetter: @escaping SCKStateResetter = { }
    ) {
        self.store = PermissionStore(defaults: defaults)
        self.passiveCheck = passiveCheck
        self.primeCheck = primeCheck
        self.interactiveCheck = interactiveCheck
        self.alertPresenter = alertPresenter
        self.alertRequestedRelaunch = alertRequestedRelaunch
        self.permissionRequester = permissionRequester
        self.identityProvider = identityProvider
        self.statusMessageSink = statusMessageSink
        self.now = now
        self.repairSCKAccess = repairSCKAccess
        self.resetTCCEntry = resetTCCEntry
        self.relaunchApp = relaunchApp
        self.sckStateResetter = sckStateResetter
    }

    /// Perform a non-interactive permission check and update the published UI model.
    @discardableResult
    func refreshPassiveStatus() async -> ScreenRecordingState {
        await refreshPassiveStatus(source: .passive)
    }

    func armPendingCaptureResume(mode: CaptureMode) {
        pendingCaptureResumeRequiresRelaunch = false
        store.armPendingResume(mode: mode, at: now())
    }

    func clearPendingCaptureResume() {
        pendingCaptureResumeRequiresRelaunch = false
        store.clearPendingResume()
    }

    func clearPendingCaptureResumeIfNoRelaunchPending() {
        guard !pendingCaptureResumeRequiresRelaunch else {
            return
        }
        clearPendingCaptureResume()
    }

    func takePendingCaptureResumeIfFresh() -> CaptureMode? {
        pendingCaptureResumeRequiresRelaunch = false
        guard let pending = store.takePendingResumeIfFresh(
            ttl: pendingCaptureResumeTTLSeconds,
            now: now()
        ) else {
            return nil
        }
        store.beginRequestSession(at: pending.requestedAt, didAutoRelaunch: true)
        return pending.mode
    }

    func coreGraphicsPreflightIsAuthoritative() -> Bool {
        let timestamp = now()
        return store.activeRequestSession(now: timestamp) == nil
            && store.liveValidatedFingerprint == nil
    }

    /// Perform a non-blocking live validation once CoreGraphics already
    /// reports granted access. Failures stay advisory so onboarding can
    /// keep the first-capture CTA as the primary action.
    @discardableResult
    func primeIfPermissionGranted() async -> ScreenRecordingState {
        let identity = await identityProvider()
        if isLiveValidatedIdentity(identity) {
            return publishStatus(.working, identity: identity, source: .passive)
        }

        guard passiveCheck() else {
            return publishDenied(identity, source: .passive)
        }

        let probeResult = await primeCheck()
        logger.info(
            "prime_validation_result result=\(String(describing: probeResult), privacy: .public)"
        )

        if probeResult == .authorized {
            return publishWorkingValidated(identity, source: .passive)
        }
        if probeResult == .configurationFailure {
            return publishStatus(.configurationFailed, identity: identity, source: .passive)
        }

        return publishStatus(.grantedNeedsValidation, identity: identity, source: .passive)
    }

    /// Run a full interactive validation (CG + SCK) triggered by an explicit user action.
    /// Automatically attempts replayd repair if SCK fails but CG is granted.
    @discardableResult
    func runUserInitiatedValidation() async -> ScreenRecordingState {
        await serializedValidation { [self] in
            await runUserInitiatedValidationCore()
        }
    }

    private func runUserInitiatedValidationCore() async -> ScreenRecordingState {
        sckStateResetter()
        let identity = await identityProvider()
        let cgGranted = passiveCheck()
        let timestamp = now()
        logger.info("interactive_check_start cg_granted=\(cgGranted, privacy: .public)")

        guard cgGranted
            || shouldTrustLiveValidationWithoutCoreGraphics(at: timestamp) else {
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

    /// Prompt macOS to grant screen recording permission via the system dialog.
    func requestPermissionFromSystem() -> Bool {
        logger.info("request_permission user_initiated=true")
        store.clearDiagnosedFailure()
        store.beginRequestSession(at: now())
        return permissionRequester()
    }

    /// Poll passive TCC state after the user returns from System Settings,
    /// then run live validation even if CoreGraphics still looks stale.
    @discardableResult
    func revalidateAfterSettingsReturn(
        timeoutSeconds: TimeInterval = 10,
        pollIntervalNanoseconds: UInt64 = 350_000_000,
        sckRetryDelayNanoseconds: UInt64 = 1_000_000_000,
        maxSCKRetries: Int = 5
    ) async -> ScreenRecordingState {
        await serializedValidation { [self] in
            await revalidateAfterSettingsReturnCore(
                timeoutSeconds: timeoutSeconds,
                pollIntervalNanoseconds: pollIntervalNanoseconds,
                sckRetryDelayNanoseconds: sckRetryDelayNanoseconds,
                maxSCKRetries: maxSCKRetries
            )
        }
    }

    private func revalidateAfterSettingsReturnCore(
        timeoutSeconds: TimeInterval,
        pollIntervalNanoseconds: UInt64,
        sckRetryDelayNanoseconds: UInt64,
        maxSCKRetries: Int
    ) async -> ScreenRecordingState {
        sckStateResetter()
        let identity = await identityProvider()
        let startedAt = now()
        guard PermissionRecoveryPlanner.settingsReturnEntryStep(
            hasFreshRequestSession: hasFreshPermissionRequestSession(at: startedAt)
        ) == .pollForValidation else {
            // .fallBackToPassiveRefresh — no fresh grant attempt to poll for.
            return await refreshPassiveStatus(source: .serializedFlow)
        }

        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        var attemptedRepair = false

        while now() < deadline {
            if PermissionRecoveryPlanner.settingsReturnPollStep(
                hasLiveValidatedIdentity: isLiveValidatedIdentity(identity)
            ) == .publishWorkingAlreadyValidated {
                clearPermissionRequestSession()
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

    /// Handle a capture failure due to missing permission, showing an alert if not rate-limited.
    /// Silently attempts replayd repair first when CG is granted.
    func handleCapturePermissionFailure() async {
        _ = await serializedValidation { [self] in
            await handleCapturePermissionFailureCore()
        }
    }

    private func handleCapturePermissionFailureCore() async -> ScreenRecordingState {
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

    /// Reset the TCC entry, restart replayd to clear its approval cache,
    /// then relaunch so the system re-prompts for permission.
    @discardableResult
    func performTCCResetAndRelaunch() async -> Bool {
        guard await resetTCCEntry() else {
            statusMessageSink("Screen Recording reset failed. Restart Caloura and try again.")
            clearPendingCaptureResume()
            return false
        }
        _ = await repairSCKAccess()
        pendingCaptureResumeRequiresRelaunch = true
        relaunchApp()
        return true
    }

}

extension PermissionCoordinator {
    /// Pure query. `updateUIModel` reassigns `permissionUIModel` from scratch
    /// using this value, and `scheduleCooldownReset` clears the model flag
    /// when the timer fires — so this method does not need a write side effect.
    func isCooldownActive(at timestamp: Date) -> Bool {
        store.isAlertCooldownActive(now: timestamp)
    }
}

private extension PermissionCoordinator {
    func serializedValidation(
        _ operation: @escaping @MainActor () async -> ScreenRecordingState
    ) async -> ScreenRecordingState {
        if let inFlight = inFlightValidation {
            return await inFlight.value
        }
        let task = Task { @MainActor in await operation() }
        inFlightValidation = task
        // defer ensures the in-flight slot clears even if the calling task is
        // cancelled mid-await. Without this, subsequent callers would co-await
        // a dead task forever, identical-shape regression to D4 cursor leak.
        // The slot must clear BEFORE the deferred-passive flush so the
        // re-publication passes the gate it was deferred by (INVARIANT-3).
        defer {
            inFlightValidation = nil
            flushDeferredPassivePublication()
        }
        return await task.value
    }

    func refreshPassiveStatus(source: PublicationSource) async -> ScreenRecordingState {
        let identity = await identityProvider()
        let timestamp = now()
        clearExpiredPermissionRequestSessionIfNeeded(at: timestamp)
        let cgGranted = passiveCheck()
        let execPath = identity.executablePath
        let signingType = identity.signingIdentityType
        let passiveMsg = "passive_check cg_granted=\(cgGranted)"
            + " path=\(execPath) signing=\(signingType)"
        logger.info("\(passiveMsg, privacy: .public)")

        #if DEBUG
        if !cgGranted, identity.bundleIdentifier.contains(".debug") {
            let warnMsg = "Debug bundle ID '\(identity.bundleIdentifier)'"
                + " — System Settings toggle is for the release bundle ID"
            logger.warning("\(warnMsg, privacy: .public)")
        }
        #endif

        return publishPassiveStatus(
            for: identity,
            at: timestamp,
            cgGranted: cgGranted,
            source: source
        )
    }

    @discardableResult
    func publishPassiveStatus(
        for identity: PermissionIdentity,
        at timestamp: Date,
        cgGranted: Bool,
        source: PublicationSource
    ) -> ScreenRecordingState {
        let status = PermissionStatusCore.passiveStatus(
            cgGranted: cgGranted,
            context: makeStatusContext(for: identity, at: timestamp)
        )
        return publishStatus(status, identity: identity, source: source)
    }

    @discardableResult
    func publishWorkingValidated(
        _ identity: PermissionIdentity,
        clearPermissionRequest: Bool = true,
        source: PublicationSource
    ) -> ScreenRecordingState {
        recordWorkingIdentity(identity)
        if clearPermissionRequest {
            clearPermissionRequestSession()
        }
        return publishStatus(.working, identity: identity, source: source)
    }

    @discardableResult
    func publishDenied(
        _ identity: PermissionIdentity,
        clearPermissionRequest: Bool = false,
        source: PublicationSource
    ) -> ScreenRecordingState {
        if clearPermissionRequest {
            clearPermissionRequestSession()
        }
        return publishStatus(.denied, identity: identity, source: source)
    }

    @discardableResult
    func publishExplicitFailure(
        for identity: PermissionIdentity,
        clearPermissionRequest: Bool = false,
        source: PublicationSource
    ) -> ScreenRecordingState {
        if clearPermissionRequest {
            clearPermissionRequestSession()
        }
        let status = PermissionStatusCore.explicitFailureStatus(
            for: makeStatusContext(for: identity, at: now())
        )
        recordDiagnosedFailure(status, for: identity)
        return publishStatus(status, identity: identity, source: source)
    }

    @discardableResult
    func publishStatus(
        _ status: ScreenRecordingState,
        identity: PermissionIdentity,
        source: PublicationSource
    ) -> ScreenRecordingState {
        publish(.model(status: status, identity: identity), source: source)
        return status
    }

    /// The single publication path: every write to `permissionUIModel`
    /// flows through here (the declaration default is the only exception).
    /// Gate rules, in order:
    /// 1. Diagnosis preservation is unchanged — `.working`/`.denied`
    ///    publications clear the pinned diagnosis only when they actually
    ///    apply (INVARIANT-5).
    /// 2. While a serialized flow is in flight, `.passive` publications are
    ///    deferred (coalesced into `deferredPassiveEvidence`) instead of
    ///    overwriting in-progress flow state (INVARIANT-3).
    /// 3. `.serializedFlow` publications always apply.
    func publish(_ candidate: PublicationCandidate, source: PublicationSource) {
        if source == .passive, inFlightValidation != nil {
            deferPassivePublication(candidate)
            return
        }
        switch candidate {
        case let .model(status, identity):
            switch status {
            case .working, .denied:
                clearDiagnosedFailure()
            case .grantedNeedsValidation,
                 .needsRelaunch,
                 .staleRecord,
                 .repairing,
                 .configurationFailed:
                break
            }
            updateUIModel(status: status, identity: identity)
        case let .alertCooldown(isActive):
            permissionUIModel.isAlertCooldownActive = isActive
        }
    }

    func deferPassivePublication(_ candidate: PublicationCandidate) {
        switch candidate {
        case let .model(status, identity):
            // Coalesce: the latest passive attempt wins. Re-sample the raw
            // CG signal now so completion-time re-evaluation works from the
            // evidence of this attempt, not a stale pre-flow capture.
            deferredPassiveEvidence = DeferredPassiveEvidence(
                identity: identity,
                cgGranted: passiveCheck()
            )
            let deferMsg = "publication_deferred kind=model status=\(String(describing: status))"
            logger.debug("\(deferMsg, privacy: .public)")
        case .alertCooldown:
            hasDeferredCooldownRefresh = true
            logger.debug("publication_deferred kind=cooldown")
        }
    }

    /// Re-evaluates evidence deferred while a serialized flow held the gate.
    /// Runs against FRESH store state (diagnosis, live validation, request
    /// session) so the flow's outcome is respected: e.g. evidence captured
    /// before the flow validated `.working` still re-publishes `.working`,
    /// and a pinned diagnosis survives exactly as it would for a sequential
    /// passive refresh (INVARIANT-5).
    func flushDeferredPassivePublication() {
        defer { hasDeferredCooldownRefresh = false }
        if let evidence = deferredPassiveEvidence {
            deferredPassiveEvidence = nil
            let status = PermissionStatusCore.passiveStatus(
                cgGranted: evidence.cgGranted,
                context: makeStatusContext(for: evidence.identity, at: now())
            )
            let flushMsg = "deferred_passive_republish status=\(String(describing: status))"
            logger.info("\(flushMsg, privacy: .public)")
            publish(.model(status: status, identity: evidence.identity), source: .passive)
            return  // a model publication recomputes the cooldown flag from the store
        }
        if hasDeferredCooldownRefresh {
            publish(.alertCooldown(isActive: isCooldownActive(at: now())), source: .passive)
        }
    }

    func makeStatusContext(
        for identity: PermissionIdentity,
        at timestamp: Date
    ) -> PermissionStatusContext {
        PermissionStatusContext(
            identity: identity,
            hasFreshPermissionRequest: hasFreshPermissionRequestSession(at: timestamp),
            hasLiveValidatedIdentity: isLiveValidatedIdentity(identity),
            isKnownWorkingIdentity: isKnownWorkingIdentity(identity),
            lastWorkingExecutablePathMatches: lastWorkingExecutablePathMatches(identity),
            diagnosedFailureStatus: diagnosedFailureStatus(for: identity),
            hasKnownWorkingMismatch: hasKnownWorkingMismatch(for: identity),
            didAutoRelaunchAfterRequest: store.requestSession?.didAutoRelaunch == true
        )
    }

    // MARK: - Recovery step execution
    // `PermissionRecoveryPlanner` decides; these helpers execute the steps.

    /// Shared terminal surface: consume the pending resume, emit the
    /// non-blocking message, refresh the cooldown flag.
    @discardableResult
    func surfaceNonBlockingStatus(_ status: ScreenRecordingState, cooldownActive: Bool) -> ScreenRecordingState {
        clearPendingCaptureResume()
        statusMessageSink(nonBlockingMessage(for: status))
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
        let canRepairRelaunch = interactiveResult == .transientFailure && canAttemptAutoRepairRelaunch()
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
        markAutoRepairRelaunchAttempted()
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
            canAutoRelaunch: canAutoRelaunchAfterSettingsReturn(at: now())
        )
        switch deadlineStep {
        case .autoRelaunchWithTCCReset:
            if let pendingMode = pendingCaptureResumeMode() {
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

    func updateCooldownInModel(cooldownActive: Bool) {
        // Only called from inside serialized flows, so it holds the gate.
        publish(.alertCooldown(isActive: cooldownActive), source: .serializedFlow)
        if cooldownActive {
            scheduleCooldownReset()
        }
    }

    func scheduleCooldownReset() {
        cooldownResetTask?.cancel()
        let seconds = store.alertCooldownSeconds
        cooldownResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // Timer fires outside any flow, so this is a passive publication.
            self?.publish(.alertCooldown(isActive: false), source: .passive)
        }
    }

    func knownWorkingFingerprint() -> String? {
        store.lastWorkingIdentity().fingerprint
    }

    func isKnownWorkingIdentity(_ identity: PermissionIdentity) -> Bool {
        guard let lastWorkingFingerprint = knownWorkingFingerprint() else {
            return false
        }
        if lastWorkingFingerprint == identity.fingerprint {
            return true
        }
        // Path-relaxed match: accept the record if the signing identity
        // matches. DerivedData iteration changes executablePath but keeps
        // signing info stable, so the prior grant still applies.
        let storedSigningKey = PermissionIdentity.trustedSigningKey(
            fromStoredFingerprint: lastWorkingFingerprint
        )
        return storedSigningKey == identity.trustedSigningKey
    }

    func isLiveValidatedIdentity(_ identity: PermissionIdentity) -> Bool {
        store.liveValidatedFingerprint == identity.fingerprint
    }

    func lastWorkingExecutablePath() -> String? {
        store.lastWorkingIdentity().executablePath
    }

    func lastWorkingExecutablePathMatches(_ identity: PermissionIdentity) -> Bool {
        lastWorkingExecutablePath() == identity.executablePath
    }

    func shouldTrustLiveValidationWithoutCoreGraphics(at timestamp: Date) -> Bool {
        hasFreshPermissionRequestSession(at: timestamp)
            || store.liveValidatedFingerprint != nil
    }

    func hasFreshPermissionRequestSession(at timestamp: Date) -> Bool {
        store.activeRequestSession(now: timestamp) != nil
    }

    func clearExpiredPermissionRequestSessionIfNeeded(at timestamp: Date) {
        _ = store.activeRequestSession(now: timestamp)
    }

    func clearPermissionRequestSession() {
        store.clearRequestSession()
    }

    func pendingCaptureResumeMode() -> CaptureMode? {
        store.pendingResumeMode()
    }

    func canAttemptAutoRepairRelaunch() -> Bool {
        store.canAutoRepairRelaunch(now: now())
    }

    func markAutoRepairRelaunchAttempted() {
        store.markAutoRepairRelaunchAttempted(at: now())
    }

    func canAutoRelaunchAfterSettingsReturn(at timestamp: Date) -> Bool {
        guard let session = store.activeRequestSession(now: timestamp) else {
            return false
        }
        return !session.didAutoRelaunch
    }

    func markAutoRelaunchIssued() {
        guard store.requestSession != nil else {
            return
        }
        store.markRequestSessionAutoRelaunched()
        pendingCaptureResumeRequiresRelaunch = true
    }

    func hasKnownWorkingMismatch(for identity: PermissionIdentity) -> Bool {
        guard let lastWorkingFingerprint = knownWorkingFingerprint() else {
            return false
        }
        // A stale-record alert should only fire when the *signing identity*
        // changed (different team / re-signed binary). Differences in the
        // executable path alone (DerivedData iteration) are not stale —
        // macOS continues to honor the grant for the same signed identity.
        let storedSigningKey = PermissionIdentity.trustedSigningKey(
            fromStoredFingerprint: lastWorkingFingerprint
        ) ?? lastWorkingFingerprint
        return storedSigningKey != identity.trustedSigningKey
    }

    func recordWorkingIdentity(_ identity: PermissionIdentity) {
        store.recordWorkingIdentity(identity)
    }

    func diagnosedFailureStatus(for identity: PermissionIdentity) -> ScreenRecordingState? {
        guard let diagnosedFailure = store.diagnosedFailure,
              diagnosedFailure.identityFingerprint == identity.fingerprint else {
            return nil
        }
        return diagnosedFailure.status
    }

    func recordDiagnosedFailure(_ status: ScreenRecordingState, for identity: PermissionIdentity) {
        guard status == .needsRelaunch || status == .staleRecord else {
            return
        }
        store.setDiagnosedFailure(
            PermissionStore.DiagnosedFailure(
                identityFingerprint: identity.fingerprint,
                status: status
            )
        )
    }

    func clearDiagnosedFailure() {
        store.clearDiagnosedFailure()
    }

    func updateUIModel(status: ScreenRecordingState, identity: PermissionIdentity) {
        let timestamp = now()
        permissionUIModel = PermissionStatusCore.uiModel(
            status: status,
            context: makeStatusContext(for: identity, at: timestamp),
            cooldownActive: isCooldownActive(at: timestamp)
        )
    }

    func nonBlockingMessage(for status: ScreenRecordingState) -> String {
        PermissionStatusCore.nonBlockingMessage(for: status)
    }
}
