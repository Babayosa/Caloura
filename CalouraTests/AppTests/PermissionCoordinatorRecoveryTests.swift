import Foundation
import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorRecoveryTests: XCTestCase {

    func testRepeatedPermissionAlertsClearIsShowingAlertBetweenCalls() async {
        // INVARIANT-4: stateful flags use defer-based clearing — the
        // isShowingAlert flag must clear on every scope exit so later
        // failures stay observable instead of being silently suppressed.
        // Regression: isShowingAlert was assigned `= false` directly after
        // the await. If the surrounding task was cancelled mid-await, the
        // assignment never ran and every subsequent permission failure was
        // silently suppressed. The defer pattern guarantees the flag clears
        // on every scope exit, including cancellation propagation.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var alertCount = 0
        var currentDate = Date(timeIntervalSince1970: 10_000)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("defer") },
            statusMessageSink: { _ in },
            now: { currentDate }
        )

        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 1)

        // Past the cooldown so suppression cannot come from cooldown logic.
        // If defer didn't run, isShowingAlert would be stuck-true and the
        // second alert would be suppressed by the inflight check.
        currentDate = currentDate.addingTimeInterval(120)
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(
            alertCount,
            2,
            "second alert must fire — defer must have cleared isShowingAlert after the first await"
        )

        currentDate = currentDate.addingTimeInterval(120)
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 3, "third alert must fire — flag must keep clearing across iterations")
    }

    func testSerializedValidationClearsInFlightSlotBetweenCalls() async {
        // INVARIANT-4: in-flight Task slots use defer-based clearing so a
        // stuck slot can never make every later caller co-await a dead task.
        // Regression: inFlightValidation was assigned `= nil` directly after
        // `await task.value`. If the awaiting task was cancelled, the
        // assignment never ran and subsequent callers co-awaited a dead
        // task. defer ensures the slot clears across cancellation paths.
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var passiveResult = false
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { passiveResult },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("inflight") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_000) }
        )

        let first = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(first, .denied)

        // Second call must run a fresh validation (different observable
        // result) rather than returning the cached first result. If the
        // in-flight slot were stuck, both calls would return the same value.
        passiveResult = true
        let second = await coordinator.refreshPassiveStatus()
        XCTAssertNotEqual(second, .denied, "second call must execute a fresh operation, not co-await a dead task")
    }
}
