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
        // The CoreFoundation type ID guard establishes the concrete Security type here.
        // swiftlint:disable:next force_cast
        self.requirement = requirementRef as! SecRequirement
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
    typealias InteractiveCheck = () async -> Bool
    typealias AlertPresenter = (ScreenCaptureManager.PermissionState) async -> Void
    typealias PermissionRequester = () -> Bool
    typealias IdentityProvider = () async -> PermissionIdentity
    typealias StatusMessageSink = (String) -> Void
    typealias NowProvider = () -> Date
    typealias RepairCheck = () async -> Bool
    typealias TCCReset = () async -> Void
    typealias Relauncher = () -> Void

    @Published private(set) var permissionUIModel = PermissionUIModel()

    private let defaults: UserDefaults
    private let passiveCheck: PassiveCheck
    private let interactiveCheck: InteractiveCheck
    private let alertPresenter: AlertPresenter
    private let permissionRequester: PermissionRequester
    private let identityProvider: IdentityProvider
    private let statusMessageSink: StatusMessageSink
    private let now: NowProvider
    private let repairSCKAccess: RepairCheck
    private let resetTCCEntry: TCCReset
    private let relaunchApp: Relauncher
    private let logger = Logger(subsystem: "com.caloura.app", category: "Permission")

    private var isShowingAlert = false
    private var lastBlockingAlertAt: Date?
    private let alertCooldownSeconds: TimeInterval = 45
    private var cooldownResetTask: Task<Void, Never>?

    private enum Keys {
        static let lastWorkingIdentityFingerprint = "permissionLastWorkingIdentityFingerprint"
        static let lastShownStaleRecordIdentityFingerprint = "permissionLastShownMismatchIdentityFingerprint"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.passiveCheck = { ScreenCaptureManager.shared.passivePermissionGranted() }
        self.interactiveCheck = { await ScreenCaptureManager.shared.validateSCKAccessUserInitiated() }
        self.alertPresenter = { state in ScreenCaptureManager.shared.showPermissionAlert(for: state) }
        self.permissionRequester = { ScreenCaptureManager.shared.requestPermission() }
        self.identityProvider = { await PermissionIdentityProvider.shared.currentIdentity() }
        self.statusMessageSink = { AppState.shared.statusMessage = $0 }
        self.now = Date.init
        self.repairSCKAccess = { await ScreenCaptureManager.shared.repairSCKAccess() }
        self.resetTCCEntry = { await ScreenCaptureManager.shared.resetTCCEntry() }
        self.relaunchApp = { ScreenCaptureManager.shared.relaunchApp() }
    }

    init(
        defaults: UserDefaults,
        passiveCheck: @escaping PassiveCheck,
        interactiveCheck: @escaping InteractiveCheck,
        alertPresenter: @escaping AlertPresenter,
        permissionRequester: @escaping PermissionRequester,
        identityProvider: @escaping IdentityProvider,
        statusMessageSink: @escaping StatusMessageSink,
        now: @escaping NowProvider,
        repairSCKAccess: @escaping RepairCheck = { false },
        resetTCCEntry: @escaping TCCReset = { },
        relaunchApp: @escaping Relauncher = { }
    ) {
        self.defaults = defaults
        self.passiveCheck = passiveCheck
        self.interactiveCheck = interactiveCheck
        self.alertPresenter = alertPresenter
        self.permissionRequester = permissionRequester
        self.identityProvider = identityProvider
        self.statusMessageSink = statusMessageSink
        self.now = now
        self.repairSCKAccess = repairSCKAccess
        self.resetTCCEntry = resetTCCEntry
        self.relaunchApp = relaunchApp
    }

    /// Perform a non-interactive permission check and update the published UI model.
    @discardableResult
    func refreshPassiveStatus() async -> ScreenRecordingState {
        let identity = await identityProvider()
        let cgGranted = passiveCheck()
        let execPath = identity.executablePath
        let signingType = identity.signingIdentityType
        let passiveMsg = "passive_check cg_granted=\(cgGranted)"
            + " path=\(execPath) signing=\(signingType)"
        logger.info("\(passiveMsg, privacy: .public)")

        let status: ScreenRecordingState
        if !cgGranted {
            status = .denied
        } else if isStalePermissionRecord(identity) {
            status = .staleRecord
        } else if isKnownWorkingIdentity(identity) {
            status = .working
        } else {
            status = .grantedNeedsValidation
        }
        updateUIModel(status: status, identity: identity)
        return status
    }

    /// Run a full interactive validation (CG + SCK) triggered by an explicit user action.
    /// Automatically attempts replayd repair if SCK fails but CG is granted.
    @discardableResult
    func runUserInitiatedValidation() async -> ScreenRecordingState {
        let identity = await identityProvider()
        let cgGranted = passiveCheck()
        logger.info("interactive_check_start cg_granted=\(cgGranted, privacy: .public)")

        guard cgGranted else {
            updateUIModel(status: .denied, identity: identity)
            return .denied
        }

        let sckAuthorized = await interactiveCheck()
        logger.info("interactive_check_result sck_authorized=\(sckAuthorized, privacy: .public)")

        if sckAuthorized {
            defaults.set(identity.fingerprint, forKey: Keys.lastWorkingIdentityFingerprint)
            updateUIModel(status: .working, identity: identity)
            return .working
        }

        // SCK failed — attempt auto-repair via replayd restart
        updateUIModel(status: .repairing, identity: identity)
        logger.info("auto_repair_start")
        let repaired = await repairSCKAccess()
        logger.info("auto_repair_result repaired=\(repaired, privacy: .public)")

        if repaired {
            defaults.set(identity.fingerprint, forKey: Keys.lastWorkingIdentityFingerprint)
            updateUIModel(status: .working, identity: identity)
            return .working
        }

        let status: ScreenRecordingState
        if isStalePermissionRecord(identity) {
            status = .staleRecord
        } else {
            status = .needsRelaunch
        }

        updateUIModel(status: status, identity: identity)
        return status
    }

    /// Prompt macOS to grant screen recording permission via the system dialog.
    func requestPermissionFromSystem() -> Bool {
        logger.info("request_permission user_initiated=true")
        return permissionRequester()
    }

    /// Poll passive TCC state after the user returns from System Settings,
    /// then run one interactive validation once macOS reports access.
    @discardableResult
    func revalidateAfterSettingsReturn(
        timeoutSeconds: TimeInterval = 4,
        pollIntervalNanoseconds: UInt64 = 350_000_000
    ) async -> ScreenRecordingState {
        let deadline = now().addingTimeInterval(timeoutSeconds)

        while now() < deadline {
            let passiveStatus = await refreshPassiveStatus()
            switch passiveStatus {
            case .denied:
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            case .staleRecord:
                return .staleRecord
            case .grantedNeedsValidation, .working, .needsRelaunch, .repairing:
                return await runUserInitiatedValidation()
            }
        }

        return await refreshPassiveStatus()
    }

    /// Handle a capture failure due to missing permission, showing an alert if not rate-limited.
    /// Silently attempts replayd repair first when CG is granted.
    func handleCapturePermissionFailure() async {
        let identity = await identityProvider()
        let status = await refreshPassiveStatus()

        // If CG is granted, attempt silent repair before showing any alert
        if status != .denied {
            logger.info("silent_repair_attempt before alert")
            let repaired = await repairSCKAccess()
            if repaired {
                logger.info("silent_repair_success — no alert needed")
                defaults.set(identity.fingerprint, forKey: Keys.lastWorkingIdentityFingerprint)
                updateUIModel(status: .working, identity: identity)
                return
            }
        }

        let now = now()
        let cooldownActive = isCooldownActive(at: now)

        if isShowingAlert {
            logger.info("permission_alert_suppressed reason=inflight status=\(String(describing: status), privacy: .public)")
            statusMessageSink(nonBlockingMessage(for: status))
            updateCooldownInModel(cooldownActive: true)
            return
        }

        if cooldownActive {
            logger.info("permission_alert_suppressed reason=cooldown status=\(String(describing: status), privacy: .public)")
            statusMessageSink(nonBlockingMessage(for: status))
            updateCooldownInModel(cooldownActive: true)
            return
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
    }

    /// Reset the TCC entry and relaunch so the system re-prompts for permission.
    func performTCCResetAndRelaunch() async {
        await resetTCCEntry()
        relaunchApp()
    }

    /// Record that the stale-record banner has been shown for the current identity.
    func markCurrentStaleRecordBannerShown() async {
        let identity = await identityProvider()
        defaults.set(identity.fingerprint, forKey: Keys.lastShownStaleRecordIdentityFingerprint)
        if permissionUIModel.status == .staleRecord {
            permissionUIModel.shouldShowStaleRecordBanner = false
        }
        logger.info("stale_record_banner_marked_shown fingerprint=\(identity.fingerprint, privacy: .private(mask: .hash))")
    }

    private func alertState(for status: ScreenRecordingState) -> ScreenCaptureManager.PermissionState {
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

    private func isCooldownActive(at timestamp: Date) -> Bool {
        guard let lastBlockingAlertAt else { return false }
        return timestamp.timeIntervalSince(lastBlockingAlertAt) < alertCooldownSeconds
    }

    private func updateCooldownInModel(cooldownActive: Bool) {
        permissionUIModel.isAlertCooldownActive = cooldownActive
        if cooldownActive {
            scheduleCooldownReset()
        }
    }

    private func scheduleCooldownReset() {
        cooldownResetTask?.cancel()
        let seconds = alertCooldownSeconds
        cooldownResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.permissionUIModel.isAlertCooldownActive = false
        }
    }

    private func knownWorkingFingerprint() -> String? {
        guard let fingerprint = defaults.string(forKey: Keys.lastWorkingIdentityFingerprint),
              !fingerprint.isEmpty else {
            return nil
        }
        return fingerprint
    }

    private func isKnownWorkingIdentity(_ identity: PermissionIdentity) -> Bool {
        knownWorkingFingerprint() == identity.fingerprint
    }

    private func isStalePermissionRecord(_ identity: PermissionIdentity) -> Bool {
        guard let lastWorkingFingerprint = knownWorkingFingerprint() else {
            return false
        }
        return lastWorkingFingerprint != identity.fingerprint
    }

    private func updateUIModel(status: ScreenRecordingState, identity: PermissionIdentity) {
        let shouldShowStaleRecordBanner = shouldShowStaleRecordBanner(for: identity, status: status)
        let guidance = guidance(for: status, identity: identity)
        let cooldownActive = isCooldownActive(at: now())
        permissionUIModel = PermissionUIModel(
            status: status,
            guidanceText: guidance,
            shouldShowStaleRecordBanner: shouldShowStaleRecordBanner,
            isAlertCooldownActive: cooldownActive
        )
    }

    private func shouldShowStaleRecordBanner(
        for identity: PermissionIdentity,
        status: ScreenRecordingState
    ) -> Bool {
        guard status == .staleRecord else { return false }
        let alreadyShownForIdentity = defaults.string(forKey: Keys.lastShownStaleRecordIdentityFingerprint)
        return alreadyShownForIdentity != identity.fingerprint
    }

    private func guidance(for status: ScreenRecordingState, identity: PermissionIdentity) -> String? {
        switch status {
        case .staleRecord:
            return "macOS appears to trust a different Caloura copy. "
                + "Open /Applications/Caloura.app, then re-grant Screen Recording for that copy if needed."
        case .needsRelaunch:
            return "Screen Recording is granted, but macOS needs a Caloura relaunch to fully apply it."
        case .denied:
            return "Caloura needs Screen Recording access to capture screenshots."
        case .grantedNeedsValidation:
            return "Screen Recording looks granted. Start a capture to finish validation."
        case .repairing:
            return "Restarting screen recording service."
        case .working:
            return nil
        }
    }

    private func nonBlockingMessage(for status: ScreenRecordingState) -> String {
        switch status {
        case .staleRecord:
            return "Screen Recording appears tied to a different Caloura copy. Open /Applications/Caloura.app and try again."
        case .denied:
            return "Screen Recording permission required. Open System Settings to continue capturing."
        case .needsRelaunch:
            return "macOS still needs Caloura to relaunch before capture is available."
        case .grantedNeedsValidation, .working, .repairing:
            return "Screen Recording is still initializing. Try again in a moment."
        }
    }
}
