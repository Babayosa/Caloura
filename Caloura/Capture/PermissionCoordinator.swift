import CryptoKit
import Foundation
import os.log
import Security

private struct SecRequirementHandle {
    let requirement: SecRequirement

    init?(rawValue: Any) {
        let requirementRef = rawValue as CFTypeRef
        guard CFGetTypeID(requirementRef) == SecRequirementGetTypeID() else {
            return nil
        }
        self.requirement = unsafeDowncast(requirementRef as AnyObject, to: SecRequirement.self)
    }

    func stringValue() -> String? {
        var requirementCFString: CFString?
        let status = SecRequirementCopyString(requirement, SecCSFlags(), &requirementCFString)
        guard status == errSecSuccess else {
            return nil
        }
        return requirementCFString as String?
    }
}

enum ScreenRecordingState: Equatable {
    case denied
    case grantedNeedsValidation
    case working
    case needsRelaunch
    case staleRecord
    case repairing
}

typealias PermissionStatus = ScreenRecordingState

struct PermissionUIModel: Equatable {
    var status: ScreenRecordingState = .grantedNeedsValidation
    var guidanceText: String?
    var shouldShowStaleRecordBanner: Bool = false
    var isAlertCooldownActive: Bool = false
}

struct PermissionIdentity: Equatable {
    let bundleIdentifier: String
    let executablePath: String
    let teamIdentifier: String
    let signingIdentityType: String
    let designatedRequirementHash: String

    /// A combined string uniquely identifying this app's signing and location attributes.
    var fingerprint: String {
        [
            bundleIdentifier,
            executablePath,
            teamIdentifier,
            signingIdentityType,
            designatedRequirementHash
        ].joined(separator: "|")
    }

    /// Build the identity for the currently running app bundle.
    static func current(bundle: Bundle = .main) -> PermissionIdentity {
        let bundleID = bundle.bundleIdentifier ?? "unknown.bundle"
        let executablePath = bundle.executableURL?.path ?? bundle.bundleURL.path

        let signingInfo = SigningInfo.load(for: bundle.bundleURL)
        let teamIdentifier = signingInfo.teamIdentifier ?? "unknown.team"
        let signingType = signingInfo.signingIdentityType ?? inferSigningType(from: executablePath)
        let requirementSeed = signingInfo.designatedRequirementString
            ?? fallbackRequirementSeed(
                bundleID: bundleID,
                executablePath: executablePath,
                teamIdentifier: teamIdentifier
            )
        let requirementHash = sha256Hex(requirementSeed)

        return PermissionIdentity(
            bundleIdentifier: bundleID,
            executablePath: executablePath,
            teamIdentifier: teamIdentifier,
            signingIdentityType: signingType,
            designatedRequirementHash: requirementHash
        )
    }

    private static func inferSigningType(from path: String) -> String {
        if path.contains("/DerivedData/") {
            return "apple-development"
        }
        if path.hasPrefix("/Applications/") {
            return "developer-id-or-release"
        }
        return "unknown"
    }

    private static func fallbackRequirementSeed(
        bundleID: String,
        executablePath: String,
        teamIdentifier: String
    ) -> String {
        "\(bundleID)|\(teamIdentifier)|\(executablePath)"
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct SigningInfo {
        let designatedRequirementString: String?
        let teamIdentifier: String?
        let signingIdentityType: String?

        static func load(for bundleURL: URL) -> SigningInfo {
            var staticCode: SecStaticCode?
            let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
            guard createStatus == errSecSuccess, let staticCode else {
                return SigningInfo(designatedRequirementString: nil, teamIdentifier: nil, signingIdentityType: nil)
            }

            var rawInfo: CFDictionary?
            let infoStatus = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &rawInfo
            )
            guard infoStatus == errSecSuccess, let info = rawInfo as? [String: Any] else {
                return SigningInfo(designatedRequirementString: nil, teamIdentifier: nil, signingIdentityType: nil)
            }

            let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
            let requirementString: String? = {
                guard let requirementValue = info[kSecCodeInfoDesignatedRequirement as String] else {
                    return nil
                }
                return SecRequirementHandle(rawValue: requirementValue)?.stringValue()
            }()

            let signingType: String? = {
                guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
                      let leaf = certificates.first else { return nil }
                let summary = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
                if summary.contains("Developer ID") {
                    return "developer-id"
                }
                if summary.contains("Apple Development") {
                    return "apple-development"
                }
                return "other"
            }()

            return SigningInfo(
                designatedRequirementString: requirementString,
                teamIdentifier: teamID,
                signingIdentityType: signingType
            )
        }
    }
}

@MainActor
final class PermissionCoordinator: ObservableObject {
    static let shared = PermissionCoordinator()

    typealias PassiveCheck = () -> Bool
    typealias PrimeCheck = () async -> ScreenCaptureAccessProbeResult
    typealias InteractiveCheck = () async -> ScreenCaptureAccessProbeResult
    typealias AlertPresenter = (ScreenCaptureManager.PermissionState) async -> Void
    typealias PermissionRequester = () -> Bool
    typealias IdentityProvider = () async -> PermissionIdentity
    typealias StatusMessageSink = (String) -> Void
    typealias NowProvider = () -> Date
    typealias RepairCheck = () async -> ScreenCaptureAccessProbeResult
    typealias TCCReset = () async -> Void
    typealias Relauncher = () -> Void
    typealias SCKStateResetter = () -> Void

    @Published private(set) var permissionUIModel = PermissionUIModel()

    private let defaults: UserDefaults
    private let passiveCheck: PassiveCheck
    private let primeCheck: PrimeCheck
    private let interactiveCheck: InteractiveCheck
    private let alertPresenter: AlertPresenter
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
    private var lastBlockingAlertAt: Date?
    private let alertCooldownSeconds: TimeInterval = 45
    private let permissionRequestLifetimeSeconds: TimeInterval = 180
    private let pendingCaptureResumeTTLSeconds: TimeInterval = 120
    private var cooldownResetTask: Task<Void, Never>?
    private var liveValidatedIdentityFingerprint: String?
    private var recentPermissionRequestSession: PermissionRequestSession?
    private var diagnosedFailure: DiagnosedFailure?

    private enum Keys {
        static let lastWorkingIdentityFingerprint = "permissionLastWorkingIdentityFingerprint"
        static let lastWorkingExecutablePath = "permissionLastWorkingExecutablePath"
        static let pendingCaptureResumeRequestedAt = "permissionPendingCaptureResumeRequestedAt"
    }

    private struct PermissionRequestSession {
        let startedAt: Date
        var didAutoRelaunch = false
    }

    private struct DiagnosedFailure {
        let identityFingerprint: String
        let status: ScreenRecordingState
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.passiveCheck = { ScreenCaptureManager.shared.passivePermissionGranted() }
        self.primeCheck = { await ScreenCaptureManager.shared.primeSCKAccessIfPossible() }
        self.interactiveCheck = { await ScreenCaptureManager.shared.validateSCKAccessUserInitiated() }
        self.alertPresenter = { state in ScreenCaptureManager.shared.showPermissionAlert(for: state) }
        self.permissionRequester = { ScreenCaptureManager.shared.requestPermission() }
        self.identityProvider = { await PermissionIdentityProvider.shared.currentIdentity() }
        self.statusMessageSink = { AppState.shared.statusMessage = $0 }
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
        permissionRequester: @escaping PermissionRequester,
        identityProvider: @escaping IdentityProvider,
        statusMessageSink: @escaping StatusMessageSink,
        now: @escaping NowProvider,
        repairSCKAccess: @escaping RepairCheck = { .transientFailure },
        resetTCCEntry: @escaping TCCReset = { },
        relaunchApp: @escaping Relauncher = { },
        sckStateResetter: @escaping SCKStateResetter = { }
    ) {
        self.defaults = defaults
        self.passiveCheck = passiveCheck
        self.primeCheck = primeCheck
        self.interactiveCheck = interactiveCheck
        self.alertPresenter = alertPresenter
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

    func armPendingCaptureResume() {
        defaults.set(now(), forKey: Keys.pendingCaptureResumeRequestedAt)
    }

    func clearPendingCaptureResume() {
        defaults.removeObject(forKey: Keys.pendingCaptureResumeRequestedAt)
    }

    func takePendingCaptureResumeIfFresh() -> Bool {
        defer { clearPendingCaptureResume() }
        guard let requestedAt = defaults.object(forKey: Keys.pendingCaptureResumeRequestedAt) as? Date else {
            return false
        }
        guard now().timeIntervalSince(requestedAt) <= pendingCaptureResumeTTLSeconds else {
            return false
        }
        recentPermissionRequestSession = PermissionRequestSession(
            startedAt: requestedAt,
            didAutoRelaunch: true
        )
        return true
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

        if isKnownWorkingIdentity(identity) {
            return publishStatus(.working, identity: identity)
        }

        let probeResult = await primeCheck()
        logger.info(
            "prime_validation_result result=\(String(describing: probeResult), privacy: .public)"
        )

        if probeResult == .authorized {
            return publishWorkingValidated(identity)
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
            armPendingCaptureResume()
            markAutoRelaunchIssued()
            _ = publishStatus(.repairing, identity: identity)
            logger.info("settings_return_auto_relaunch")
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
            logger.info("silent_repair_attempt best_effort=true")
            let repairResult = await repairSCKAccess()
            if repairResult == .authorized {
                logger.info("silent_repair_success — no alert needed")
                _ = publishWorkingValidated(identity, clearPermissionRequest: false)
                return .working
            }
            logger.info("silent_repair_did_not_resolve — proceeding to alert")
            status = publishExplicitFailure(for: identity)
        }

        let now = now()
        let cooldownActive = isCooldownActive(at: now)

        if isShowingAlert {
            logger.info("permission_alert_suppressed reason=inflight status=\(String(describing: status), privacy: .public)")
            statusMessageSink(nonBlockingMessage(for: status))
            updateCooldownInModel(cooldownActive: true)
            return status
        }

        if cooldownActive {
            logger.info("permission_alert_suppressed reason=cooldown status=\(String(describing: status), privacy: .public)")
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
        await alertPresenter(alertState)
        isShowingAlert = false
        lastBlockingAlertAt = now
        updateCooldownInModel(cooldownActive: true)
        return status
    }

    /// Reset the TCC entry, restart replayd to clear its approval cache,
    /// then relaunch so the system re-prompts for permission.
    func performTCCResetAndRelaunch() async {
        await resetTCCEntry()
        _ = await repairSCKAccess()
        relaunchApp()
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
        let result = await task.value
        inFlightValidation = nil
        return result
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
        case .grantedNeedsValidation, .needsRelaunch, .staleRecord, .repairing:
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
             .repairing:
            return .grantedButFailing
        }
    }

    func isCooldownActive(at timestamp: Date) -> Bool {
        guard let lastBlockingAlertAt else { return false }
        return timestamp.timeIntervalSince(lastBlockingAlertAt) < alertCooldownSeconds
    }

    func updateCooldownInModel(cooldownActive: Bool) {
        permissionUIModel.isAlertCooldownActive = cooldownActive
        if cooldownActive {
            scheduleCooldownReset()
        }
    }

    func scheduleCooldownReset() {
        cooldownResetTask?.cancel()
        let seconds = alertCooldownSeconds
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
        knownWorkingFingerprint() == identity.fingerprint
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
    }

    func hasKnownWorkingMismatch(for identity: PermissionIdentity) -> Bool {
        guard let lastWorkingFingerprint = knownWorkingFingerprint() else {
            return false
        }
        return lastWorkingFingerprint != identity.fingerprint
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
