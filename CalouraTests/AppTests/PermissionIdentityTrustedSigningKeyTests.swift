import XCTest
@testable import Caloura

@MainActor
final class PermissionIdentityTrustedSigningKeyTests: XCTestCase {

    // MARK: PermissionIdentity.trustedSigningKey

    func testTrustedSigningKeyExcludesExecutablePath() {
        let identity = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/Applications/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "developer-id-or-release",
            designatedRequirementHash: "hash-abc"
        )

        XCTAssertEqual(
            identity.trustedSigningKey,
            "com.caloura.app|NG4ML6Q47T|developer-id-or-release|hash-abc"
        )
    }

    func testTwoIdentitiesDifferingOnlyByExecutablePathShareTrustedSigningKey() {
        let devBuild = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/var/DerivedData/A/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "apple-development",
            designatedRequirementHash: "hash-abc"
        )
        let nextDebug = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/var/DerivedData/B/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "apple-development",
            designatedRequirementHash: "hash-abc"
        )

        XCTAssertNotEqual(devBuild.fingerprint, nextDebug.fingerprint)
        XCTAssertEqual(devBuild.trustedSigningKey, nextDebug.trustedSigningKey)
    }

    func testDifferentDesignatedRequirementProducesDifferentTrustedSigningKey() {
        let original = PermissionTestHelpers.makeIdentity("team-a")
        let reSigned = PermissionIdentity(
            bundleIdentifier: original.bundleIdentifier,
            executablePath: original.executablePath,
            teamIdentifier: "DIFFERENT_TEAM",
            signingIdentityType: original.signingIdentityType,
            designatedRequirementHash: "hash-different"
        )

        XCTAssertNotEqual(original.trustedSigningKey, reSigned.trustedSigningKey)
    }

    func testTrustedSigningKeyRoundTripsThroughStoredFingerprint() {
        let identity = PermissionTestHelpers.makeIdentity("round-trip")
        let recovered = PermissionIdentity.trustedSigningKey(
            fromStoredFingerprint: identity.fingerprint
        )

        XCTAssertEqual(recovered, identity.trustedSigningKey)
    }

    func testTrustedSigningKeyRecoveryReturnsNilForMalformedFingerprint() {
        XCTAssertNil(
            PermissionIdentity.trustedSigningKey(fromStoredFingerprint: "too|few|columns")
        )
    }

    // MARK: Stale-record behavior in the coordinator

    func testDerivedDataRelaunchDoesNotAppearStale() async {
        // Simulate: a previous build registered a known-working fingerprint
        // whose executablePath now differs (new DerivedData location) but
        // whose signing identity is identical.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let firstBuild = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/var/DerivedData/old/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "apple-development",
            designatedRequirementHash: "req-hash-stable"
        )
        let secondBuild = PermissionIdentity(
            bundleIdentifier: firstBuild.bundleIdentifier,
            executablePath: "/var/DerivedData/new/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: firstBuild.teamIdentifier,
            signingIdentityType: firstBuild.signingIdentityType,
            designatedRequirementHash: firstBuild.designatedRequirementHash
        )
        defaults.set(firstBuild.fingerprint, forKey: "permissionLastWorkingIdentityFingerprint")
        defaults.set(firstBuild.executablePath, forKey: "permissionLastWorkingExecutablePath")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { secondBuild },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 20_000) }
        )

        let status = await coordinator.refreshPassiveStatus()

        // The trusted-signing-key relaxation suppresses stale-record UI, but
        // passive history still cannot replace a live validation.
        XCTAssertEqual(status, .grantedNeedsValidation)
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
    }

    func testDifferentDesignatedRequirementDoesNotReturnWorking() async {
        // Simulate: a stored known-working identity from a different team
        // or re-signed binary. Trusted signing keys must differ, so the
        // coordinator does NOT shortcut the current identity to .working.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let oldIdentity = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/Applications/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: "TEAM_OLD",
            signingIdentityType: "developer-id-or-release",
            designatedRequirementHash: "req-hash-old"
        )
        let currentIdentity = PermissionIdentity(
            bundleIdentifier: oldIdentity.bundleIdentifier,
            executablePath: oldIdentity.executablePath,
            teamIdentifier: "TEAM_NEW",
            signingIdentityType: oldIdentity.signingIdentityType,
            designatedRequirementHash: "req-hash-new"
        )
        defaults.set(oldIdentity.fingerprint, forKey: "permissionLastWorkingIdentityFingerprint")
        defaults.set(oldIdentity.executablePath, forKey: "permissionLastWorkingExecutablePath")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { currentIdentity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 21_000) }
        )

        let status = await coordinator.refreshPassiveStatus()

        // Different signing identity should never resolve to .working off a
        // passive check alone.
        XCTAssertNotEqual(status, .working)
    }
}
