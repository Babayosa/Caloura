import Foundation
import os.log

/// Single owner of all durable and session-scoped Screen Recording
/// permission state. Centralizes the UserDefaults keys that used to be
/// scattered across `PermissionCoordinator` plus the in-memory session
/// state (live-validated fingerprint, request session, diagnosed failure)
/// so the values stay mutually consistent and every mutation has an
/// intention-revealing entry point. No other type touches these keys.
@MainActor
final class PermissionStore {

    struct WorkingIdentityRecord: Equatable {
        let fingerprint: String?
        let executablePath: String?
    }

    struct RequestSession: Equatable {
        let startedAt: Date
        var didAutoRelaunch: Bool
    }

    struct PendingResume: Equatable {
        let mode: CaptureMode
        let requestedAt: Date
    }

    struct DiagnosedFailure: Equatable {
        let identityFingerprint: String
        let status: ScreenRecordingState
    }

    private enum Keys {
        static let lastWorkingIdentityFingerprint = "permissionLastWorkingIdentityFingerprint"
        static let lastWorkingExecutablePath = "permissionLastWorkingExecutablePath"
        static let pendingCaptureResumeRequestedAt = "permissionPendingCaptureResumeRequestedAt"
        static let pendingCaptureResumeMode = "permissionPendingCaptureResumeMode"
        static let lastAutoRepairRelaunchAt = "permissionLastAutoRepairRelaunchAt"
        static let lastBlockingAlertAt = "permissionLastBlockingAlertAt"
    }

    /// Most recently live-validated identity fingerprint for this process.
    /// Session-scoped: dies with the process by design (a relaunch must
    /// re-validate against SCK before trusting the grant again).
    private(set) var liveValidatedFingerprint: String?

    /// Raw request session (no freshness applied). Prefer
    /// `activeRequestSession(now:)` unless the caller explicitly needs the
    /// stale value (e.g. UI guidance for an in-flight auto-relaunch).
    private(set) var requestSession: RequestSession?

    /// Hard diagnosis (.needsRelaunch / .staleRecord) pinned to a specific
    /// identity fingerprint so passive refreshes cannot revert it.
    private(set) var diagnosedFailure: DiagnosedFailure?

    var alertCooldownSeconds: TimeInterval { cooldownPolicy.alertCooldownSeconds }

    private let defaults: UserDefaults
    private let cooldownPolicy: PermissionCooldownPolicy
    private let requestSessionLifetimeSeconds: TimeInterval
    private let logger = Logger(subsystem: "com.caloura.app", category: "Permission")

    init(
        defaults: UserDefaults = .standard,
        cooldownPolicy: PermissionCooldownPolicy = PermissionCooldownPolicy(),
        requestSessionLifetimeSeconds: TimeInterval = 180
    ) {
        self.defaults = defaults
        self.cooldownPolicy = cooldownPolicy
        self.requestSessionLifetimeSeconds = requestSessionLifetimeSeconds
    }

    // MARK: - Last working identity (durable)

    func recordWorkingIdentity(_ identity: PermissionIdentity) {
        clearDiagnosedFailure()
        recordLiveValidation(fingerprint: identity.fingerprint)
        defaults.set(identity.fingerprint, forKey: Keys.lastWorkingIdentityFingerprint)
        defaults.set(identity.executablePath, forKey: Keys.lastWorkingExecutablePath)
    }

    func lastWorkingIdentity() -> WorkingIdentityRecord {
        WorkingIdentityRecord(
            fingerprint: nonEmptyString(forKey: Keys.lastWorkingIdentityFingerprint),
            executablePath: nonEmptyString(forKey: Keys.lastWorkingExecutablePath)
        )
    }

    // MARK: - Pending capture resume (durable)

    func armPendingResume(mode: CaptureMode, at timestamp: Date) {
        defaults.set(timestamp, forKey: Keys.pendingCaptureResumeRequestedAt)
        defaults.set(mode.rawValue, forKey: Keys.pendingCaptureResumeMode)
    }

    func clearPendingResume() {
        defaults.removeObject(forKey: Keys.pendingCaptureResumeRequestedAt)
        defaults.removeObject(forKey: Keys.pendingCaptureResumeMode)
    }

    /// Non-consuming peek at the armed resume mode (used to re-arm before
    /// an auto-relaunch without burning the single-use take below).
    func pendingResumeMode() -> CaptureMode? {
        guard let rawMode = defaults.string(forKey: Keys.pendingCaptureResumeMode) else {
            return nil
        }
        return CaptureMode(rawValue: rawMode)
    }

    /// Single-use take: consumes the pending resume on every call (fresh,
    /// stale, or malformed) so a failed resume can never replay later.
    func takePendingResumeIfFresh(ttl: TimeInterval, now: Date) -> PendingResume? {
        defer { clearPendingResume() }
        guard let requestedAt = defaults.object(forKey: Keys.pendingCaptureResumeRequestedAt) as? Date else {
            return nil
        }
        guard now.timeIntervalSince(requestedAt) <= ttl else {
            return nil
        }
        guard let rawMode = defaults.string(forKey: Keys.pendingCaptureResumeMode),
              let mode = CaptureMode(rawValue: rawMode) else {
            return nil
        }
        return PendingResume(mode: mode, requestedAt: requestedAt)
    }

    // MARK: - Auto-repair relaunch cooldown (durable)

    func markAutoRepairRelaunchAttempted(at timestamp: Date) {
        defaults.set(timestamp, forKey: Keys.lastAutoRepairRelaunchAt)
    }

    func canAutoRepairRelaunch(now: Date) -> Bool {
        cooldownPolicy.canAttemptAutoRepairRelaunch(
            lastAttemptAt: defaults.object(forKey: Keys.lastAutoRepairRelaunchAt) as? Date,
            at: now
        )
    }

    // MARK: - Blocking alert cooldown (durable — survives relaunch so a
    // crash/relaunch loop cannot re-spam the same modal alert)

    func noteBlockingAlertShown(at timestamp: Date) {
        defaults.set(timestamp, forKey: Keys.lastBlockingAlertAt)
    }

    func isAlertCooldownActive(now: Date) -> Bool {
        cooldownPolicy.isAlertCooldownActive(
            lastBlockingAlertAt: defaults.object(forKey: Keys.lastBlockingAlertAt) as? Date,
            at: now
        )
    }

    // MARK: - Permission request session (in-memory)

    func beginRequestSession(at timestamp: Date, didAutoRelaunch: Bool = false) {
        requestSession = RequestSession(startedAt: timestamp, didAutoRelaunch: didAutoRelaunch)
    }

    /// Returns the session while it is fresh; prunes it once expired so a
    /// stale grant attempt cannot keep overriding CGPreflight indefinitely.
    func activeRequestSession(now: Date) -> RequestSession? {
        guard let session = requestSession else {
            return nil
        }
        guard now.timeIntervalSince(session.startedAt) <= requestSessionLifetimeSeconds else {
            requestSession = nil
            return nil
        }
        return session
    }

    func markRequestSessionAutoRelaunched() {
        guard var session = requestSession else {
            return
        }
        session.didAutoRelaunch = true
        requestSession = session
    }

    func clearRequestSession() {
        requestSession = nil
    }

    // MARK: - Live validation (in-memory)

    func recordLiveValidation(fingerprint: String) {
        liveValidatedFingerprint = fingerprint
    }

    // MARK: - Diagnosed failure (in-memory)

    func setDiagnosedFailure(_ failure: DiagnosedFailure) {
        diagnosedFailure = failure
    }

    func clearDiagnosedFailure() {
        diagnosedFailure = nil
    }

    // MARK: - Derived status context

    /// One evidence snapshot per evaluation: every status decision reads
    /// store state through this single gathering point, so the rules in
    /// `PermissionStatusCore` always see mutually consistent values.
    /// Calling it prunes an expired request session as a side effect of
    /// the freshness check.
    func statusContext(for identity: PermissionIdentity, at timestamp: Date) -> PermissionStatusContext {
        PermissionStatusContext(
            identity: identity,
            hasFreshPermissionRequest: activeRequestSession(now: timestamp) != nil,
            hasLiveValidatedIdentity: isLiveValidatedIdentity(identity),
            isKnownWorkingIdentity: isKnownWorkingIdentity(identity),
            lastWorkingExecutablePathMatches: lastWorkingIdentity().executablePath == identity.executablePath,
            diagnosedFailureStatus: diagnosedFailureStatus(for: identity),
            hasKnownWorkingMismatch: hasKnownWorkingMismatch(for: identity),
            didAutoRelaunchAfterRequest: requestSession?.didAutoRelaunch == true
        )
    }

    func isLiveValidatedIdentity(_ identity: PermissionIdentity) -> Bool {
        liveValidatedFingerprint == identity.fingerprint
    }

    func isKnownWorkingIdentity(_ identity: PermissionIdentity) -> Bool {
        guard let lastWorkingFingerprint = lastWorkingIdentity().fingerprint else {
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

    func hasKnownWorkingMismatch(for identity: PermissionIdentity) -> Bool {
        guard let lastWorkingFingerprint = lastWorkingIdentity().fingerprint else {
            return false
        }
        // A stale-record alert should only fire when the *signing identity*
        // changed (different team / re-signed binary). Differences in the
        // executable path alone (DerivedData iteration) are not stale —
        // macOS continues to honor the grant for the same signed identity
        // (INVARIANT-9).
        let storedSigningKey = PermissionIdentity.trustedSigningKey(
            fromStoredFingerprint: lastWorkingFingerprint
        ) ?? lastWorkingFingerprint
        return storedSigningKey != identity.trustedSigningKey
    }

    func diagnosedFailureStatus(for identity: PermissionIdentity) -> ScreenRecordingState? {
        guard let diagnosedFailure, diagnosedFailure.identityFingerprint == identity.fingerprint else {
            return nil
        }
        return diagnosedFailure.status
    }

    /// INVARIANT-1: after an explicit grant attempt (fresh request session)
    /// or a live validation in this process, trust live SCK even while
    /// CGPreflight still reports denied.
    func shouldTrustLiveValidationWithoutCoreGraphics(at timestamp: Date) -> Bool {
        activeRequestSession(now: timestamp) != nil || liveValidatedFingerprint != nil
    }

    /// One auto-relaunch per request session (settings-return deadline path).
    func canAutoRelaunchAfterSettingsReturn(at timestamp: Date) -> Bool {
        guard let session = activeRequestSession(now: timestamp) else {
            return false
        }
        return !session.didAutoRelaunch
    }

    // MARK: - Identity change

    /// Clears exactly the state an identity change invalidates: the
    /// live-validated fingerprint, the pinned diagnosis, and the grant
    /// request session — all are fingerprint/grant-attempt scoped.
    /// Durable state deliberately survives: `lastWorkingIdentity` is the
    /// input to stale-record detection (it must describe the OLD identity),
    /// pending resume survives relaunch by design, and both cooldowns
    /// rate-limit the user, not an identity.
    func resetForIdentityChange() {
        logger.info("permission_store_reset_for_identity_change")
        liveValidatedFingerprint = nil
        diagnosedFailure = nil
        requestSession = nil
    }

    private func nonEmptyString(forKey key: String) -> String? {
        guard let value = defaults.string(forKey: key), !value.isEmpty else {
            return nil
        }
        return value
    }
}
