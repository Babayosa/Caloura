import CryptoKit
import Foundation
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

    /// Identity key used when deciding whether the macOS Screen Recording
    /// grant on disk actually applies to *this* copy of the app. Excludes
    /// `executablePath` so iterative Debug builds (which write to a new
    /// DerivedData path each time) do not appear as a different Caloura
    /// and trigger stale-record alerts. The designated-requirement hash
    /// still catches different-team or re-signed copies.
    var trustedSigningKey: String {
        [
            bundleIdentifier,
            teamIdentifier,
            signingIdentityType,
            designatedRequirementHash
        ].joined(separator: "|")
    }

    /// Recover the trusted signing key from a previously-stored fingerprint
    /// without needing a new UserDefaults key. The fingerprint layout above
    /// has the executablePath at column 1; this drops that column.
    static func trustedSigningKey(fromStoredFingerprint fingerprint: String) -> String? {
        let parts = fingerprint.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        return [parts[0], parts[2], parts[3], parts[4]].joined(separator: "|")
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
        let requirementHash = SHA256Hex.encode(requirementSeed)

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
