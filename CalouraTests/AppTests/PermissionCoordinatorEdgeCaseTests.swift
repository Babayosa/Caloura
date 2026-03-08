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
            pollIntervalNanoseconds: 1_000_000
        )

        XCTAssertEqual(status, .staleRecord)
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
