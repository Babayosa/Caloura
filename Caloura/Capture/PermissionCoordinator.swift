import Foundation
import Observation
import os.log

enum ScreenRecordingState: Equatable {
    case denied
    case grantedNeedsValidation
    case working
    case needsRelaunch
    case staleRecord
    case repairing
    case configurationFailed
}

struct PermissionUIModel: Equatable {
    var status: ScreenRecordingState = .grantedNeedsValidation
    var guidanceText: String?
    var shouldShowStaleRecordBanner: Bool = false
    var isAlertCooldownActive: Bool = false
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

    private let defaults: UserDefaults
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
    private var isShowingAlert = false
    private var cooldownPolicy: PermissionCooldownPolicy
    private let permissionRequestLifetimeSeconds: TimeInterval = 180
    private let pendingCaptureResumeTTLSeconds: TimeInterval = 120
    private var cooldownResetTask: Task<Void, Never>?
    private var liveValidatedIdentityFingerprint: String?
    private var recentPermissionRequestSession: PermissionRequestSession?
    private var diagnosedFailure: DiagnosedFailure?
    private var pendingCaptureResumeRequiresRelaunch = false

    private enum Keys {
        static let lastWorkingIdentityFingerprint = "permissionLastWorkingIdentityFingerprint"
        static let lastWorkingExecutablePath = "permissionLastWorkingExecutablePath"
        static let pendingCaptureResumeRequestedAt = "permissionPendingCaptureResumeRequestedAt"
        static let pendingCaptureResumeMode = "permissionPendingCaptureResumeMode"
        static let lastAutoRepairRelaunchAt = "permissionLastAutoRepairRelaunchAt"
    }

    private struct PermissionRequestSession {
        let startedAt: Date
        var didAutoRelaunch = false
    }

    private struct DiagnosedFailure {
        let identityFingerprint: String
        let status: ScreenRecordingState
    }

    @MainActor
    private final class AlertDecisionBox {
        var lastAction: ScreenCapturePermissionAlertAction = .cancel
    }

    init(defaults: UserDefaults = .standard) {
        let alertDecision = AlertDecisionBox()
        self.defaults = defaults
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
        self.cooldownPolicy = PermissionCooldownPolicy(
            defaults: defaults,
            lastAutoRepairRelaunchKey: Keys.lastAutoRepairRelaunchAt
        )
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
        self.defaults = defaults
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
        self.cooldownPolicy = PermissionCooldownPolicy(
            defaults: defaults,
            lastAutoRepairRelaunchKey: Keys.lastAutoRepairRelaunchAt,
            now: now
        )
    }

    /// Perform a non-interactive permission check and update the published UI model.
    @discardableResult
    func refreshPassiveStatus() async -> ScreenRecordingState {
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
            cgGranted: cgGranted
        )
    }

    func armPendingCaptureResume(mode: CaptureMode) {
        pendingCaptureResumeRequiresRelaunch = false
        defaults.set(now(), forKey: Keys.pendingCaptureResumeRequestedAt)
        defaults.set(mode.rawValue, forKey: Keys.pendingCaptureResumeMode)
    }

    func clearPendingCaptureResume() {
        pendingCaptureResumeRequiresRelaunch = false
        defaults.removeObject(forKey: Keys.pendingCaptureResumeRequestedAt)
        defaults.removeObject(forKey: Keys.pendingCaptureResumeMode)
    }

    func clearPendingCaptureResumeIfNoRelaunchPending() {
        guard !pendingCaptureResumeRequiresRelaunch else {
            return
        }
        clearPendingCaptureResume()
    }

    func takePendingCaptureResumeIfFresh() -> CaptureMode? {
        defer { clearPendingCaptureResume() }
        guard let requestedAt = defaults.object(forKey: Keys.pendingCaptureResumeRequestedAt) as? Date else {
            return nil
        }
        guard now().timeIntervalSince(requestedAt) <= pendingCaptureResumeTTLSeconds else {
            return nil
        }
        guard let rawMode = defaults.string(forKey: Keys.pendingCaptureResumeMode),
              let mode = CaptureMode(rawValue: rawMode) else {
            return nil
        }
        recentPermissionRequestSession = PermissionRequestSession(
            startedAt: requestedAt,
            didAutoRelaunch: true
        )
        pendingCaptureResumeRequiresRelaunch = false
        return mode
    }

    func coreGraphicsPreflightIsAuthoritative() -> Bool {
        let timestamp = now()
        clearExpiredPermissionRequestSessionIfNeeded(at: timestamp)
        return recentPermissionRequestSession == nil
            && liveValidatedIdentityFingerprint == nil
    }

    /// Perform a non-blocking live validation once CoreGraphics already
    /// reports granted access. Failures stay advisory so onboarding can
    /// keep the first-capture CTA as the primary action.
    @discardableResult
    func primeIfPermissionGranted() async -> ScreenRecordingState {
        let identity = await identityProvider()
        if isLiveValidatedIdentity(identity) {
            return publishStatus(.working, identity: identity)
        }

        guard passiveCheck() else {
            return publishDenied(identity)
        }

        let probeResult = await primeCheck()
        logger.info(
            "prime_validation_result result=\(String(describing: probeResult), privacy: .public)"
        )

        if probeResult == .authorized {
            return publishWorkingValidated(identity)
        }
        if probeResult == .configurationFailure {
            return publishStatus(.configurationFailed, identity: identity)
        }

        return publishStatus(.grantedNeedsValidation, identity: identity)
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
            return publishDenied(identity)
        }

        let validationResult = await interactiveCheck()
        logger.info(
            "interactive_check_result result=\(String(describing: validationResult), privacy: .public)"
        )

        if validationResult == .authorized {
            return publishWorkingValidated(identity)
        }
        if validationResult == .configurationFailure {
            return publishStatus(.configurationFailed, identity: identity)
        }

        // SCK failed — attempt auto-repair via replayd restart (best-effort on Tahoe)
        _ = publishStatus(.repairing, identity: identity)
        logger.info("auto_repair_start best_effort=true")
        let repairResult = await repairSCKAccess()
        logger.info(
            "auto_repair_result result=\(String(describing: repairResult), privacy: .public)"
        )

        if repairResult == .authorized {
            return publishWorkingValidated(identity)
        }

        if repairResult == .userDeclined {
            return publishDenied(identity, clearPermissionRequest: true)
        }
        if repairResult == .configurationFailure {
            return publishStatus(.configurationFailed, identity: identity)
        }

        return publishExplicitFailure(for: identity)
    }

    /// Prompt macOS to grant screen recording permission via the system dialog.
    func requestPermissionFromSystem() -> Bool {
        logger.info("request_permission user_initiated=true")
        clearDiagnosedFailure()
        recentPermissionRequestSession = PermissionRequestSession(startedAt: now())
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
        guard hasFreshPermissionRequestSession(at: startedAt) else {
            return await refreshPassiveStatus()
        }

        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        var attemptedRepair = false

        while now() < deadline {
            if isLiveValidatedIdentity(identity) {
                clearPermissionRequestSession()
                return publishStatus(.working, identity: identity)
            }

            let cgGranted = passiveCheck()
            logger.info("settings_return_poll cg_granted=\(cgGranted, privacy: .public)")

            for attempt in 1...maxSCKRetries {
                let validationResult = await interactiveCheck()
                let validationLog = "settings_return_validation attempt=\(attempt)"
                    + " cg_granted=\(cgGranted)"
                    + " result=\(String(describing: validationResult))"
                logger.info("\(validationLog, privacy: .public)")

                switch validationResult {
                case .authorized:
                    return publishWorkingValidated(identity)
                case .userDeclined:
                    return publishDenied(identity, clearPermissionRequest: true)
                case .configurationFailure:
                    return publishStatus(.configurationFailed, identity: identity)
                case .transientFailure:
                    _ = publishStatus(.grantedNeedsValidation, identity: identity)

                    if cgGranted, !attemptedRepair {
                        attemptedRepair = true
                        _ = publishStatus(.repairing, identity: identity)
                        logger.info("settings_return_auto_repair_start best_effort=true")
                        let repairResult = await repairSCKAccess()
                        logger.info(
                            "settings_return_auto_repair_result result=\(String(describing: repairResult), privacy: .public)"
                        )

                        switch repairResult {
                        case .authorized:
                            return publishWorkingValidated(identity)
                        case .userDeclined:
                            return publishDenied(identity, clearPermissionRequest: true)
                        case .configurationFailure:
                            return publishStatus(.configurationFailed, identity: identity)
                        case .transientFailure:
                            _ = publishStatus(.grantedNeedsValidation, identity: identity)
                        }
                    }
                }

                if attempt < maxSCKRetries {
                    try? await Task.sleep(nanoseconds: sckRetryDelayNanoseconds)
                }
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        if canAutoRelaunchAfterSettingsReturn(at: now()) {
            if let pendingMode = pendingCaptureResumeMode() {
                armPendingCaptureResume(mode: pendingMode)
            }
            markAutoRelaunchIssued()
            _ = publishStatus(.repairing, identity: identity)
            logger.info("settings_return_auto_relaunch with TCC reset")
            guard await resetTCCEntry() else {
                clearPendingCaptureResume()
                return publishExplicitFailure(for: identity, clearPermissionRequest: true)
            }
            relaunchApp()
            return .repairing
        }

        return publishExplicitFailure(for: identity, clearPermissionRequest: true)
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
        var status = await refreshPassiveStatus()

        // If CG is granted, attempt silent repair before showing any alert.
        // Repair is best-effort — on Tahoe, replayd restart may be blocked by SIP.
        if status != .denied {
            if status == .configurationFailed {
                clearPendingCaptureResume()
                statusMessageSink(nonBlockingMessage(for: status))
                updateCooldownInModel(cooldownActive: false)
                return status
            }
            logger.info("silent_repair_attempt best_effort=true")
            let repairResult = await repairSCKAccess()
            if repairResult == .authorized {
                logger.info("silent_repair_success — no alert needed")
                clearPendingCaptureResume()
                _ = publishWorkingValidated(identity, clearPermissionRequest: false)
                return .working
            }
            // `.confirmRepairRelaunch` is destructive (TCC reset + forced
            // relaunch). Gate it on BOTH passive=.denied AND an interactive
            // check also failing. When CG says granted, a single capture
            // failure is not strong enough evidence of a real permission
            // problem — surface a non-blocking status instead of cascading
            // into a modal alert that greys the menu bar.
            logger.info("silent_repair_did_not_resolve — CG granted, treating as transient")
            status = publishExplicitFailure(for: identity)
            clearPendingCaptureResume()
            statusMessageSink(nonBlockingMessage(for: status))
            updateCooldownInModel(cooldownActive: false)
            return status
        }

        // Passive status is .denied. Corroborate with a live interactive
        // check before firing the destructive repair flow. If interactive
        // succeeds, TCC is stale but SCK works — a relaunch would only be
        // disruptive. If interactive also fails, the system is genuinely
        // stuck and the repair prompt is warranted.
        let interactiveResult = await interactiveCheck()
        logger.info(
            "repair_gate_interactive result=\(String(describing: interactiveResult), privacy: .public)"
        )
        if interactiveResult == .authorized {
            return publishWorkingValidated(identity)
        }
        if interactiveResult == .configurationFailure {
            let configurationStatus = publishStatus(.configurationFailed, identity: identity)
            clearPendingCaptureResume()
            statusMessageSink(nonBlockingMessage(for: configurationStatus))
            updateCooldownInModel(cooldownActive: false)
            return configurationStatus
        }

        if interactiveResult == .transientFailure,
           cooldownPolicy.canAttemptAutoRepairRelaunch(),
           isShowingAlert {
            logger.info(
                "permission_alert_suppressed reason=inflight_repair status=\(String(describing: status), privacy: .public)"
            )
        }
        if interactiveResult == .transientFailure,
           cooldownPolicy.canAttemptAutoRepairRelaunch(),
           !isShowingAlert {
            cooldownPolicy.markAutoRepairRelaunchAttempted()
            isShowingAlert = true
            // defer clears across cancellation — see CLAUDE.md "Stateful flags require recovery API + diagnostic log + defer-based clear".
            defer { isShowingAlert = false }
            await alertPresenter(.confirmRepairRelaunch)
            if alertRequestedRelaunch() {
                logger.info("user_approved_repair_relaunch — TCC reset + relaunch")
                if await performTCCResetAndRelaunch() {
                    return .repairing
                }
                return publishExplicitFailure(for: identity, clearPermissionRequest: true)
            }
            // User declined the destructive repair. Do NOT fall through
            // to a second modal alert — that's two blocking prompts
            // back-to-back for the same failure. Set the cooldown and
            // surface a non-blocking status so the user can retry.
            logger.info("user_declined_repair_relaunch — surfacing status only")
            clearPendingCaptureResume()
            statusMessageSink(nonBlockingMessage(for: status))
            cooldownPolicy.markBlockingAlertShown(at: now())
            updateCooldownInModel(cooldownActive: true)
            return status
        }

        let now = now()
        let cooldownActive = isCooldownActive(at: now)

        if isShowingAlert {
            logger.info("permission_alert_suppressed reason=inflight status=\(String(describing: status), privacy: .public)")
            clearPendingCaptureResume()
            statusMessageSink(nonBlockingMessage(for: status))
            updateCooldownInModel(cooldownActive: true)
            return status
        }

        if cooldownActive {
            logger.info("permission_alert_suppressed reason=cooldown status=\(String(describing: status), privacy: .public)")
            clearPendingCaptureResume()
            statusMessageSink(nonBlockingMessage(for: status))
            updateCooldownInModel(cooldownActive: true)
            return status
        }

        let alertState = alertState(for: status)
        let alertDesc = String(describing: alertState)
        let alertPath = identity.executablePath
        let alertMsg = "permission_alert_presenting"
            + " state=\(alertDesc) path=\(alertPath)"
        logger.info("\(alertMsg, privacy: .public)")
        isShowingAlert = true
        defer { isShowingAlert = false }  // see comment on the prior defer
        await alertPresenter(alertState)
        if alertRequestedRelaunch() {
            pendingCaptureResumeRequiresRelaunch = true
        } else {
            clearPendingCaptureResume()
        }
        cooldownPolicy.markBlockingAlertShown(at: now)
        updateCooldownInModel(cooldownActive: true)
        return status
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
        cooldownPolicy.isCooldownActive(at: timestamp)
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
        defer { inFlightValidation = nil }
        return await task.value
    }

    @discardableResult
    func publishPassiveStatus(
        for identity: PermissionIdentity,
        at timestamp: Date,
        cgGranted: Bool
    ) -> ScreenRecordingState {
        let status = PermissionStatusCore.passiveStatus(
            cgGranted: cgGranted,
            context: makeStatusContext(for: identity, at: timestamp)
        )
        return publishStatus(status, identity: identity)
    }

    @discardableResult
    func publishWorkingValidated(
        _ identity: PermissionIdentity,
        clearPermissionRequest: Bool = true
    ) -> ScreenRecordingState {
        recordWorkingIdentity(identity)
        if clearPermissionRequest {
            clearPermissionRequestSession()
        }
        return publishStatus(.working, identity: identity)
    }

    @discardableResult
    func publishDenied(
        _ identity: PermissionIdentity,
        clearPermissionRequest: Bool = false
    ) -> ScreenRecordingState {
        if clearPermissionRequest {
            clearPermissionRequestSession()
        }
        return publishStatus(.denied, identity: identity)
    }

    @discardableResult
    func publishExplicitFailure(
        for identity: PermissionIdentity,
        clearPermissionRequest: Bool = false
    ) -> ScreenRecordingState {
        if clearPermissionRequest {
            clearPermissionRequestSession()
        }
        let status = PermissionStatusCore.explicitFailureStatus(
            for: makeStatusContext(for: identity, at: now())
        )
        recordDiagnosedFailure(status, for: identity)
        return publishStatus(status, identity: identity)
    }

    @discardableResult
    func publishStatus(
        _ status: ScreenRecordingState,
        identity: PermissionIdentity
    ) -> ScreenRecordingState {
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
        return status
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
            didAutoRelaunchAfterRequest: recentPermissionRequestSession?.didAutoRelaunch == true
        )
    }

    func alertState(for status: ScreenRecordingState) -> ScreenCaptureManager.PermissionState {
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

    func updateCooldownInModel(cooldownActive: Bool) {
        permissionUIModel.isAlertCooldownActive = cooldownActive
        if cooldownActive {
            scheduleCooldownReset()
        }
    }

    func scheduleCooldownReset() {
        cooldownResetTask?.cancel()
        let seconds = cooldownPolicy.alertCooldownSeconds
        cooldownResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.permissionUIModel.isAlertCooldownActive = false
        }
    }

    func knownWorkingFingerprint() -> String? {
        guard let fingerprint = defaults.string(forKey: Keys.lastWorkingIdentityFingerprint),
              !fingerprint.isEmpty else {
            return nil
        }
        return fingerprint
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
        liveValidatedIdentityFingerprint == identity.fingerprint
    }

    func lastWorkingExecutablePath() -> String? {
        guard let path = defaults.string(forKey: Keys.lastWorkingExecutablePath),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    func lastWorkingExecutablePathMatches(_ identity: PermissionIdentity) -> Bool {
        lastWorkingExecutablePath() == identity.executablePath
    }

    func shouldTrustLiveValidationWithoutCoreGraphics(at timestamp: Date) -> Bool {
        hasFreshPermissionRequestSession(at: timestamp)
            || liveValidatedIdentityFingerprint != nil
    }

    func hasFreshPermissionRequestSession(at timestamp: Date) -> Bool {
        guard let session = recentPermissionRequestSession else {
            return false
        }
        return timestamp.timeIntervalSince(session.startedAt) <= permissionRequestLifetimeSeconds
    }

    func clearExpiredPermissionRequestSessionIfNeeded(at timestamp: Date) {
        guard !hasFreshPermissionRequestSession(at: timestamp) else {
            return
        }
        recentPermissionRequestSession = nil
    }

    func clearPermissionRequestSession() {
        recentPermissionRequestSession = nil
    }

    func pendingCaptureResumeMode() -> CaptureMode? {
        guard let rawMode = defaults.string(forKey: Keys.pendingCaptureResumeMode) else {
            return nil
        }
        return CaptureMode(rawValue: rawMode)
    }

    func canAttemptAutoRepairRelaunch() -> Bool {
        cooldownPolicy.canAttemptAutoRepairRelaunch()
    }

    func markAutoRepairRelaunchAttempted() {
        cooldownPolicy.markAutoRepairRelaunchAttempted()
    }

    func canAutoRelaunchAfterSettingsReturn(at timestamp: Date) -> Bool {
        guard hasFreshPermissionRequestSession(at: timestamp),
              let session = recentPermissionRequestSession else {
            return false
        }
        return !session.didAutoRelaunch
    }

    func markAutoRelaunchIssued() {
        guard var session = recentPermissionRequestSession else {
            return
        }
        session.didAutoRelaunch = true
        recentPermissionRequestSession = session
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
        clearDiagnosedFailure()
        liveValidatedIdentityFingerprint = identity.fingerprint
        defaults.set(identity.fingerprint, forKey: Keys.lastWorkingIdentityFingerprint)
        defaults.set(identity.executablePath, forKey: Keys.lastWorkingExecutablePath)
    }

    func diagnosedFailureStatus(for identity: PermissionIdentity) -> ScreenRecordingState? {
        guard let diagnosedFailure,
              diagnosedFailure.identityFingerprint == identity.fingerprint else {
            return nil
        }
        return diagnosedFailure.status
    }

    func recordDiagnosedFailure(_ status: ScreenRecordingState, for identity: PermissionIdentity) {
        guard status == .needsRelaunch || status == .staleRecord else {
            return
        }
        diagnosedFailure = DiagnosedFailure(
            identityFingerprint: identity.fingerprint,
            status: status
        )
    }

    func clearDiagnosedFailure() {
        diagnosedFailure = nil
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
