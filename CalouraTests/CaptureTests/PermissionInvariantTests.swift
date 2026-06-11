import Foundation
import XCTest
@testable import Caloura

/// Regression pins for design-doc invariants that no other test names
/// explicitly (tasks/permissions-rework-design.md).
@MainActor
final class PermissionInvariantTests: XCTestCase {

    func testHistoricalWorkingStateNeverBypassesSystemPermissionRequest() async {
        // INVARIANT-2: NEVER use historical working state to bypass
        // CGRequestScreenCaptureAccess() — after a tccutil reset the stored
        // known-working identity must not short-circuit past `.denied`, and
        // the explicit grant flow must still invoke the system requester
        // (otherwise the app vanishes from System Settings).
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("post-tcc-reset")
        defaults.set(identity.fingerprint, forKey: "permissionLastWorkingIdentityFingerprint")
        defaults.set(identity.executablePath, forKey: "permissionLastWorkingExecutablePath")

        var requesterCalls = 0
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: {
                requesterCalls += 1
                return true
            },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 30_000) }
        )

        let status = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(
            status,
            .denied,
            "stored working history must not bypass the system re-request"
        )
        XCTAssertEqual(requesterCalls, 0, "passive refresh must never prompt")

        XCTAssertTrue(coordinator.requestPermissionFromSystem())
        XCTAssertEqual(
            requesterCalls,
            1,
            "the explicit grant flow must reach CGRequestScreenCaptureAccess"
        )
    }

    func testPublicAPISurfaceUsedByCallSitesKeepsWorking() async {
        // INVARIANT-11: the public API used by CalouraApp, CapturePipeline,
        // OnboardingView and AppCommandController keeps working. Each call
        // below pins one documented entry point's signature and its
        // happy-path behavior.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("public-api")
        var alertCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 40_000) },
            repairSCKAccess: { .authorized }
        )

        // CapturePipeline: arm/take pending capture resume.
        coordinator.armPendingCaptureResume(mode: .area)
        XCTAssertEqual(coordinator.takePendingCaptureResumeIfFresh(), .area)
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh(), "pending resume is single-use")

        // CalouraApp: passive refresh.
        let passive = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(passive, .grantedNeedsValidation)

        // OnboardingView: user-initiated validation.
        let validated = await coordinator.runUserInitiatedValidation()
        XCTAssertEqual(validated, .working)

        // CalouraApp: prime after grant.
        let primed = await coordinator.primeIfPermissionGranted()
        XCTAssertEqual(primed, .working)

        // OnboardingView: revalidation after returning from System Settings.
        let revalidated = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 1,
            pollIntervalNanoseconds: 1_000_000
        )
        XCTAssertEqual(revalidated, .working)

        // CapturePipeline: capture-failure handling stays silent when
        // validation succeeds.
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 0, "working permission must not raise the failure alert")
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
    }
}
