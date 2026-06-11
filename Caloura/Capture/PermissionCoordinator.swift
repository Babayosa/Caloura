import Foundation
import Observation
import os.log

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

/// Facade for the Screen Recording permission system. Every flow follows
/// the same shape: evidence acquisition (`PermissionStore.statusContext`)
/// → decision (`PermissionStatusCore` rules / `PermissionRecoveryPlanner`
/// steps) → step execution (`PermissionCoordinator+RecoveryExecution`)
/// → gated publication (`publish(_:source:)` below).
@Observable @MainActor
final class PermissionCoordinator {
    static let shared = PermissionCoordinator()

    /// Where a publication originated. `.serializedFlow` writes come from
    /// inside a `serializedValidation` operation and always apply.
    /// `.passive` writes (passive refresh, prime, cooldown timer) are
    /// deferred while a serialized flow is in flight so they cannot
    /// overwrite in-progress flow state such as `.repairing` (INVARIANT-3).
    enum PublicationSource {
        case passive
        case serializedFlow
    }

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

    // Dependencies and flow state are internal (not private) because the
    // recovery flows live in `PermissionCoordinator+RecoveryExecution.swift`.
    let store: PermissionStore
    let passiveCheck: PassiveCheck
    private let primeCheck: PrimeCheck
    let interactiveCheck: InteractiveCheck
    let alertPresenter: AlertPresenter
    let alertRequestedRelaunch: AlertRelaunchRequested
    private let permissionRequester: PermissionRequester
    let identityProvider: IdentityProvider
    let statusMessageSink: StatusMessageSink
    let now: NowProvider
    let repairSCKAccess: RepairCheck
    let resetTCCEntry: TCCReset
    let relaunchApp: Relauncher
    let sckStateResetter: SCKStateResetter
    let logger = Logger(subsystem: "com.caloura.app", category: "Permission")

    private var inFlightValidation: Task<ScreenRecordingState, Never>?
    private var deferredPassiveEvidence: DeferredPassiveEvidence?
    private var hasDeferredCooldownRefresh = false
    var isShowingAlert = false
    private let pendingCaptureResumeTTLSeconds: TimeInterval = 120
    private var cooldownResetTask: Task<Void, Never>?
    var pendingCaptureResumeRequiresRelaunch = false

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
        !store.shouldTrustLiveValidationWithoutCoreGraphics(at: now())
    }

    /// Perform a non-blocking live validation once CoreGraphics already
    /// reports granted access. Failures stay advisory so onboarding can
    /// keep the first-capture CTA as the primary action.
    @discardableResult
    func primeIfPermissionGranted() async -> ScreenRecordingState {
        let identity = await identityProvider()
        if store.isLiveValidatedIdentity(identity) {
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

    /// Handle a capture failure due to missing permission, showing an alert if not rate-limited.
    /// Silently attempts replayd repair first when CG is granted.
    func handleCapturePermissionFailure() async {
        _ = await serializedValidation { [self] in
            await handleCapturePermissionFailureCore()
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
    @discardableResult
    func publishStatus(
        _ status: ScreenRecordingState,
        identity: PermissionIdentity,
        source: PublicationSource
    ) -> ScreenRecordingState {
        publish(.model(status: status, identity: identity), source: source)
        return status
    }

    func updateCooldownInModel(cooldownActive: Bool) {
        // Only called from inside serialized flows, so it holds the gate.
        publish(.alertCooldown(isActive: cooldownActive), source: .serializedFlow)
        if cooldownActive {
            scheduleCooldownReset()
        }
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
                store.clearDiagnosedFailure()
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
                context: store.statusContext(for: evidence.identity, at: now())
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

    func updateUIModel(status: ScreenRecordingState, identity: PermissionIdentity) {
        let timestamp = now()
        permissionUIModel = PermissionStatusCore.uiModel(
            status: status,
            context: store.statusContext(for: identity, at: timestamp),
            cooldownActive: isCooldownActive(at: timestamp)
        )
    }
}
