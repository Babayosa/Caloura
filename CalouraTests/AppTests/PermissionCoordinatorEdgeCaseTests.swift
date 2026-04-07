import Foundation
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

    func testRevalidateAfterSettingsReturnAutoRelaunchesBeforeStaleDecision() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("settings-stale")
        defaults.set("different-fingerprint", forKey: "permissionLastWorkingIdentityFingerprint")
        var passiveChecks = 0
        var relaunchCount = 0
        var currentTime = 16_000.0

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
            now: {
                defer { currentTime += 0.8 }
                return Date(timeIntervalSince1970: currentTime)
            },
            repairSCKAccess: { .transientFailure },
            relaunchApp: { relaunchCount += 1 }
        )

        XCTAssertTrue(coordinator.requestPermissionFromSystem())
        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 3,
            pollIntervalNanoseconds: 1_000_000,
            sckRetryDelayNanoseconds: 1_000_000,
            maxSCKRetries: 3
        )

        XCTAssertEqual(status, .repairing)
        XCTAssertEqual(relaunchCount, 1)
        XCTAssertGreaterThanOrEqual(passiveChecks, 1)
    }

    func testExplicitFailureTriesValidationForSamePathDifferentSigning() async {
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
            status, .grantedNeedsValidation,
            "Same path but different signing should try validation before escalating"
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

    func testRefreshPassiveStatusPreservesStaleRecordDiagnosisAfterInteractiveFailure() async {
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
            now: { Date(timeIntervalSince1970: 23_100) },
            repairSCKAccess: { .transientFailure }
        )

        let validationStatus = await coordinator.runUserInitiatedValidation()
        let refreshStatus = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(validationStatus, .staleRecord)
        XCTAssertEqual(refreshStatus, .staleRecord)
        XCTAssertTrue(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
    }

    // MARK: - Validation Serialization

    func testConcurrentValidationsAreSerialized() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var interactiveCallCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: {
                interactiveCallCount += 1
                try? await Task.sleep(nanoseconds: 50_000_000)
                return .authorized
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("serialize") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 30_000) }
        )

        async let first = coordinator.runUserInitiatedValidation()
        async let second = coordinator.runUserInitiatedValidation()
        let results = await [first, second]

        XCTAssertEqual(results[0], .working)
        XCTAssertEqual(results[1], .working)
        XCTAssertEqual(
            interactiveCallCount, 1,
            "Concurrent calls should share one in-flight validation"
        )
    }

    func testSerializationGateResetsAfterCompletion() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var interactiveCallCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: {
                interactiveCallCount += 1
                return .authorized
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("serialize-reset") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 31_000) }
        )

        _ = await coordinator.runUserInitiatedValidation()
        _ = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(
            interactiveCallCount, 2,
            "Sequential calls should each run their own validation"
        )
    }

}
