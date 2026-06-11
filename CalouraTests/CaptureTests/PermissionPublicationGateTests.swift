import Foundation
import XCTest
@testable import Caloura

/// S2 publication gate: passive publications must not overwrite the
/// published UI model while a serialized validation/repair flow is in
/// flight (design doc root cause H2). Deferred passive evidence is
/// re-evaluated against fresh store state once the flow completes.
@MainActor
final class PermissionPublicationGateTests: XCTestCase {

    // INVARIANT-3: interactive validation paths serialize — a passive
    // refresh racing an in-flight validation may not interleave its
    // publication mid-flow. It is applied (re-evaluated with the latest
    // evidence) only after the flow completes.
    func testPassiveRefreshDuringSerializedValidationIsDeferredThenAppliedAfterCompletion() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("gate-defer")
        let gate = AsyncGate()
        var cgGranted = true
        var interactiveEntered = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { cgGranted },
            interactiveCheck: {
                interactiveEntered = true
                await gate.wait()
                return .transientFailure
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 40_000) },
            repairSCKAccess: { .transientFailure }
        )

        let flowTask = Task { await coordinator.runUserInitiatedValidation() }
        await pollUntil { interactiveEntered }

        // CG flips to revoked while the flow is blocked inside SCK validation.
        cgGranted = false
        let passiveStatus = await coordinator.refreshPassiveStatus()

        // The caller still receives the candidate computed from the latest
        // evidence, but the published model is untouched mid-flow.
        XCTAssertEqual(passiveStatus, .denied)
        XCTAssertEqual(
            coordinator.permissionUIModel.status, .grantedNeedsValidation,
            "Passive refresh must not publish while a serialized flow holds the gate"
        )

        await gate.open()
        let flowStatus = await flowTask.value

        XCTAssertEqual(flowStatus, .needsRelaunch)
        XCTAssertEqual(
            coordinator.permissionUIModel.status, .denied,
            "Deferred passive evidence (CG revoked) must re-publish after flow completion"
        )
    }

    // INVARIANT-3: an in-progress repair publishes `.repairing`; a passive
    // refresh seeing CG granted must not downgrade it to
    // `.grantedNeedsValidation` mid-repair.
    func testPassiveRefreshDuringRepairCannotDowngradeRepairingModel() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("gate-repairing")
        let gate = AsyncGate()
        var repairEntered = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 41_000) },
            repairSCKAccess: {
                repairEntered = true
                await gate.wait()
                return .authorized
            }
        )

        let flowTask = Task { await coordinator.runUserInitiatedValidation() }
        await pollUntil { repairEntered }
        XCTAssertEqual(coordinator.permissionUIModel.status, .repairing)

        let passiveStatus = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(passiveStatus, .grantedNeedsValidation)
        XCTAssertEqual(
            coordinator.permissionUIModel.status, .repairing,
            "Passive refresh must not downgrade an in-progress repair"
        )

        await gate.open()
        let flowStatus = await flowTask.value

        XCTAssertEqual(flowStatus, .working)
        XCTAssertEqual(
            coordinator.permissionUIModel.status, .working,
            "Post-flow re-evaluation must respect the repair's live validation"
        )
    }

    // INVARIANT-5: a hard diagnosis (.needsRelaunch) must not be reverted by
    // a passive refresh. Extends the sequential case (pinned in
    // PermissionCoordinatorTests) to the deferred path: evidence deferred
    // across a flow is re-evaluated through the same diagnosis-preserving
    // rules at completion.
    func testDiagnosedNeedsRelaunchSurvivesDeferredPassiveRefreshAcrossFlow() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("gate-diagnosis")
        let gate = AsyncGate()
        var interactiveCallCount = 0
        var secondValidationEntered = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: {
                interactiveCallCount += 1
                if interactiveCallCount == 2 {
                    secondValidationEntered = true
                    await gate.wait()
                }
                return .transientFailure
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 42_000) },
            repairSCKAccess: { .transientFailure }
        )

        let diagnosedStatus = await coordinator.runUserInitiatedValidation()
        XCTAssertEqual(diagnosedStatus, .needsRelaunch)
        // Sequential passive refresh preserves the diagnosis (INVARIANT-5).
        let sequentialRefresh = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(sequentialRefresh, .needsRelaunch)

        let flowTask = Task { await coordinator.runUserInitiatedValidation() }
        await pollUntil { secondValidationEntered }

        let midFlightRefresh = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(midFlightRefresh, .needsRelaunch)
        XCTAssertEqual(coordinator.permissionUIModel.status, .needsRelaunch)

        await gate.open()
        let flowStatus = await flowTask.value

        XCTAssertEqual(flowStatus, .needsRelaunch)
        XCTAssertEqual(
            coordinator.permissionUIModel.status, .needsRelaunch,
            "Deferred passive re-evaluation must preserve the pinned diagnosis"
        )
    }

    // INVARIANT-3: the OnboardingView double-invocation race —
    // startSettingsReturnPolling has a revalidateAfterSettingsReturn flow in
    // flight when handleDidBecomeActive fires a passive refresh. The final
    // published state must reflect the serialized flow's outcome, not the
    // stale CG signal the passive refresh observed.
    func testSettingsReturnPollingWithDidBecomeActiveRefreshKeepsFlowOutcome() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("gate-onboarding")
        let gate = AsyncGate()
        var interactiveEntered = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            // CG stays stale-false after the grant — the real-world window
            // where CGPreflight and live SCK disagree.
            passiveCheck: { false },
            interactiveCheck: {
                interactiveEntered = true
                await gate.wait()
                return .authorized
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 43_000) }
        )

        XCTAssertTrue(coordinator.requestPermissionFromSystem())
        let flowTask = Task {
            await coordinator.revalidateAfterSettingsReturn(
                timeoutSeconds: 3,
                pollIntervalNanoseconds: 1_000_000,
                sckRetryDelayNanoseconds: 1_000_000
            )
        }
        await pollUntil { interactiveEntered }

        // didBecomeActive-triggered passive refresh while polling validates.
        let passiveStatus = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(passiveStatus, .grantedNeedsValidation)
        XCTAssertEqual(coordinator.permissionUIModel.status, .grantedNeedsValidation)

        await gate.open()
        let flowStatus = await flowTask.value

        XCTAssertEqual(flowStatus, .working)
        XCTAssertEqual(
            coordinator.permissionUIModel.status, .working,
            "Serialized flow outcome must win over the stale passive refresh"
        )
    }

}
