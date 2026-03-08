import Foundation
import ImageIO
import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorEdgeCaseTests: XCTestCase {

    func testRepeatedRefreshPassiveStatusStableResult() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("stable") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 10_000) }
        )

        var results: [ScreenRecordingState] = []
        for _ in 0..<20 {
            let status = await coordinator.refreshPassiveStatus()
            results.append(status)
        }

        XCTAssertTrue(results.allSatisfy { $0 == .grantedNeedsValidation })
    }

    func testRepeatedRefreshPassiveStatusDeniedIsStable() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("denied") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 11_000) }
        )

        for _ in 0..<20 {
            let status = await coordinator.refreshPassiveStatus()
            XCTAssertEqual(status, .denied)
        }

        XCTAssertEqual(coordinator.permissionUIModel.status, .denied)
    }

    func testRefreshPassiveStatusReturnsKnownWorkingForCurrentFingerprint() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("granted")
        defaults.set(identity.fingerprint, forKey: "permissionLastWorkingIdentityFingerprint")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 12_000) }
        )

        let status = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(status, .working)
    }

    func testUIModelConsistencyAfterRepeatedRefreshCalls() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("uimodel") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 13_000) }
        )

        for _ in 0..<10 {
            _ = await coordinator.refreshPassiveStatus()
        }

        let model = coordinator.permissionUIModel
        if model.status != .staleRecord {
            XCTAssertFalse(model.shouldShowStaleRecordBanner)
        }
    }

    func testPassiveMismatchDoesNotBecomeStaleRecord() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("mismatch-stable")
        defaults.set(
            "different-fingerprint",
            forKey: "permissionLastWorkingIdentityFingerprint"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 14_000) }
        )

        let first = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(first, .grantedNeedsValidation)
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowStaleRecordBanner)

        for _ in 0..<10 {
            let status = await coordinator.refreshPassiveStatus()
            XCTAssertEqual(status, .grantedNeedsValidation)
            XCTAssertFalse(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
        }
    }

    func testHandleCapturePermissionFailureRapidCallsDedupe() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var alertCount = 0
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("rapid-fail") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 15_000) }
        )

        for _ in 0..<10 {
            await coordinator.handleCapturePermissionFailure()
        }

        XCTAssertEqual(alertCount, 1)
    }

    func testRevalidateAfterSettingsReturnUsesLiveValidationBeforeStaleDecision() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("settings-stale")
        defaults.set("different-fingerprint", forKey: "permissionLastWorkingIdentityFingerprint")
        var passiveChecks = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: {
                passiveChecks += 1
                return passiveChecks >= 2
            },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 16_000 + Double(passiveChecks)) },
            repairSCKAccess: { .transientFailure }
        )

        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 3,
            pollIntervalNanoseconds: 1_000_000,
            sckRetryDelayNanoseconds: 1_000_000,
            maxSCKRetries: 3
        )

        XCTAssertEqual(status, .staleRecord)
    }

    func testExplicitFailureReturnsNeedsRelaunchForSamePathDifferentSigning() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let path = "/Applications/Caloura.app/Contents/MacOS/Caloura"

        let previousIdentity = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: path,
            teamIdentifier: "OLDTEAM",
            signingIdentityType: "developer-id",
            designatedRequirementHash: "old-hash"
        )
        defaults.set(
            previousIdentity.fingerprint,
            forKey: "permissionLastWorkingIdentityFingerprint"
        )
        defaults.set(
            previousIdentity.executablePath,
            forKey: "permissionLastWorkingExecutablePath"
        )

        let currentIdentity = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: path,
            teamIdentifier: "NEWTEAM",
            signingIdentityType: "apple-development",
            designatedRequirementHash: "new-hash"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { currentIdentity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 22_000) },
            repairSCKAccess: { .transientFailure }
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(
            status, .needsRelaunch,
            "Same path but different signing should be needsRelaunch, not staleRecord"
        )
    }

    func testExplicitFailureReturnsStaleRecordForDifferentPath() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)

        let previousIdentity = PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/Applications/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "developer-id",
            designatedRequirementHash: "prod-hash"
        )
        defaults.set(
            previousIdentity.fingerprint,
            forKey: "permissionLastWorkingIdentityFingerprint"
        )
        defaults.set(
            previousIdentity.executablePath,
            forKey: "permissionLastWorkingExecutablePath"
        )

        let currentIdentity = PermissionIdentity(
            bundleIdentifier: "com.caloura.app.debug",
            executablePath: "/Users/dev/DerivedData/Caloura/Build/Debug/Caloura.app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "apple-development",
            designatedRequirementHash: "debug-hash"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { currentIdentity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 23_000) },
            repairSCKAccess: { .transientFailure }
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(
            status, .staleRecord,
            "Different path should be staleRecord"
        )
    }

    func testReleaseScriptUsesNeutralDmgBackgroundAsset() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let releaseScriptURL = repoRoot.appendingPathComponent("scripts/release.sh")
        let assetURL = repoRoot.appendingPathComponent("scripts/assets/dmg-neutral-background.png")
        let releaseScript = try String(contentsOf: releaseScriptURL, encoding: .utf8)
        let imageSource = CGImageSourceCreateWithURL(assetURL as CFURL, nil)
        let properties = imageSource
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }

        XCTAssertTrue(releaseScript.contains("scripts/assets/dmg-neutral-background.png"))
        XCTAssertFalse(releaseScript.contains("AppIcon.appiconset/icon_512x512.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 1120)
        XCTAssertEqual(properties?[kCGImagePropertyPixelHeight] as? Int, 720)
    }
}
