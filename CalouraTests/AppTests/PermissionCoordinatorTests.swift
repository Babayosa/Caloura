import Foundation
import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorTests: XCTestCase {

    func testRefreshPassiveStatusDeniedWhenCGNotGranted() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("denied") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let status = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(coordinator.permissionUIModel.status, .denied)
    }

    func testPassiveMismatchStaysGrantedNeedsValidation() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("stale")
        defaults.set("different-fingerprint", forKey: "permissionLastWorkingIdentityFingerprint")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let firstStatus = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(firstStatus, .grantedNeedsValidation)
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
    }

    func testCaptureFailureAlertIsDedupedByCooldown() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var alertCount = 0
        var statusMessage = ""
        var currentDate = Date(timeIntervalSince1970: 3_000)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("cooldown") },
            statusMessageSink: { statusMessage = $0 },
            now: { currentDate }
        )

        await coordinator.handleCapturePermissionFailure()
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 1)
        XCTAssertFalse(statusMessage.isEmpty)

        currentDate = currentDate.addingTimeInterval(50)
        await coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 2)
    }

    func testUserInitiatedValidationTransitions() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var interactiveResult: ScreenCaptureAccessProbeResult = .transientFailure

        let firstIdentity = PermissionTestHelpers.makeIdentity("primary")
        let firstCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { interactiveResult },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { firstIdentity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_000) }
        )

        let firstStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(firstStatus, .needsRelaunch)

        interactiveResult = .authorized
        let secondStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(secondStatus, .working)

        let staleCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("secondary") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_100) },
            repairSCKAccess: { .transientFailure }
        )

        let staleStatus = await staleCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(staleStatus, .staleRecord)
    }

    func testRunUserInitiatedValidationAutoRepairsViaReplayd() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("repair-ok")
        var repairCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_000) },
            repairSCKAccess: {
                repairCalled = true
                return .authorized
            }
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertTrue(repairCalled)
        XCTAssertEqual(status, .working)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
    }

    func testRunUserInitiatedValidationRepairFailsNeedsRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("repair-fail")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_100) },
            repairSCKAccess: { .transientFailure }
        )

        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(status, .needsRelaunch)
    }

    func testRefreshPassiveStatusPreservesNeedsRelaunchDiagnosisAfterInteractiveFailure() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("preserve-needs-relaunch")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_150) },
            repairSCKAccess: { .transientFailure }
        )

        let validationStatus = await coordinator.runUserInitiatedValidation()
        let refreshStatus = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(validationStatus, .needsRelaunch)
        XCTAssertEqual(refreshStatus, .needsRelaunch)
        XCTAssertEqual(coordinator.permissionUIModel.status, .needsRelaunch)
    }

    func testHandleCapturePermissionFailureSilentRepairNoAlert() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("silent-repair")
        var alertCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 6_000) },
            repairSCKAccess: { .authorized }
        )

        coordinator.armPendingCaptureResume(mode: .window)
        await coordinator.handleCapturePermissionFailure()

        XCTAssertEqual(alertCount, 0)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }

    func testRevalidateAfterSettingsReturnTrustsLiveValidationWhileCGStaysFalse() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("return")
        var passiveChecks = 0
        var interactiveChecks = 0
        let now = makeAdvancingNow(start: 7_000, step: 0.4)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: {
                passiveChecks += 1
                return false
            },
            interactiveCheck: {
                interactiveChecks += 1
                return .authorized
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: now
        )

        XCTAssertTrue(coordinator.requestPermissionFromSystem())
        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 3,
            pollIntervalNanoseconds: 1_000_000
        )

        XCTAssertEqual(status, .working)
        XCTAssertGreaterThanOrEqual(passiveChecks, 1)
        XCTAssertEqual(interactiveChecks, 1)
    }

    func testPerformTCCResetAndRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var resetCalled = false
        var relaunchCalled = false

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("tcc-reset") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 8_000) },
            resetTCCEntry: {
                resetCalled = true
                return true
            },
            relaunchApp: { relaunchCalled = true }
        )

        await coordinator.performTCCResetAndRelaunch()

        XCTAssertTrue(resetCalled)
        XCTAssertTrue(relaunchCalled)
    }

    func testRunUserInitiatedValidationResetsSCKState() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var resetCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("sck-reset") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 20_000) },
            sckStateResetter: { resetCount += 1 }
        )

        _ = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(
            resetCount, 1,
            "SCK state should be reset before interactive validation"
        )
    }

    func testRevalidateAfterSettingsReturnResetsSCKState() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var resetCount = 0
        let now = makeAdvancingNow(start: 21_000, step: 0.5)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("sck-reset-settings") },
            statusMessageSink: { _ in },
            now: now,
            sckStateResetter: { resetCount += 1 }
        )

        XCTAssertTrue(coordinator.requestPermissionFromSystem())
        _ = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 1,
            pollIntervalNanoseconds: 1_000_000,
            sckRetryDelayNanoseconds: 1_000_000
        )

        XCTAssertEqual(
            resetCount, 1,
            "SCK state should be reset once at the start of settings-return revalidation"
        )
    }

    func testRevalidateRetriesSCKUpToThreeTimesBeforeAutoRelaunch() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var interactiveCallCount = 0
        var relaunchCount = 0
        let now = makeAdvancingNow(start: 24_000, step: 0.7)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: {
                interactiveCallCount += 1
                return .transientFailure
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("retry-exhaust") },
            statusMessageSink: { _ in },
            now: now,
            repairSCKAccess: { .transientFailure },
            relaunchApp: { relaunchCount += 1 }
        )

        XCTAssertTrue(coordinator.requestPermissionFromSystem())
        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 1,
            pollIntervalNanoseconds: 1_000_000,
            sckRetryDelayNanoseconds: 1_000_000,
            maxSCKRetries: 3
        )

        XCTAssertEqual(status, .repairing)
        XCTAssertEqual(
            interactiveCallCount, 3,
            "Should retry SCK validation up to maxSCKRetries times"
        )
        XCTAssertEqual(relaunchCount, 1)
    }

    func testRevalidateStopsRetryingOnFirstSuccess() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var interactiveCallCount = 0
        let now = makeAdvancingNow(start: 25_000, step: 0.4)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: {
                interactiveCallCount += 1
                return interactiveCallCount >= 2 ? .authorized : .transientFailure
            },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("retry-success") },
            statusMessageSink: { _ in },
            now: now,
            repairSCKAccess: { .transientFailure },
            sckStateResetter: { }
        )

        XCTAssertTrue(coordinator.requestPermissionFromSystem())
        let status = await coordinator.revalidateAfterSettingsReturn(
            timeoutSeconds: 1,
            pollIntervalNanoseconds: 1_000_000,
            sckRetryDelayNanoseconds: 1_000_000,
            maxSCKRetries: 3
        )

        XCTAssertEqual(status, .working, "Should succeed on second attempt")
        XCTAssertEqual(
            interactiveCallCount, 2,
            "Should stop retrying after first success"
        )
    }

    func testPrimeIfPermissionGrantedCachesWorkingWithoutRepairUI() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("primed")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            primeCheck: { .authorized },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 9_000) }
        )

        let status = await coordinator.primeIfPermissionGranted()

        XCTAssertEqual(status, .working)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
    }

    func testRefreshPassiveStatusStaysWorkingAfterLiveValidationSucceedsOnce() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("live-validation")
        var cgGranted = true

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { cgGranted },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: makeAdvancingNow(start: 26_000, step: 0.5)
        )

        let validationStatus = await coordinator.runUserInitiatedValidation()
        XCTAssertEqual(validationStatus, .working)

        cgGranted = false
        let refreshStatus = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(refreshStatus, .working)
    }

    func testRefreshPassiveStatusDeniedWhenOnlyLastWorkingPathExistsAndNoActiveRequest() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("same-path-refresh")
        defaults.set(
            identity.executablePath,
            forKey: "permissionLastWorkingExecutablePath"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 26_500) }
        )

        let status = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(coordinator.permissionUIModel.status, .denied)
    }

    func testRefreshPassiveStatusKeepsPendingCaptureResumeInValidationWhenCGStaysFalse() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("same-path-interactive")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 26_600) }
        )

        coordinator.armPendingCaptureResume(mode: .area)
        XCTAssertEqual(coordinator.takePendingCaptureResumeIfFresh(), .area)
        let status = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(status, .grantedNeedsValidation)
        XCTAssertEqual(coordinator.permissionUIModel.status, .grantedNeedsValidation)
    }

    func testRunUserInitiatedValidationCanSucceedWhenCGStaysFalseDuringPendingResume() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("same-path-interactive-success")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .authorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 26_650) }
        )

        coordinator.armPendingCaptureResume(mode: .window)
        XCTAssertEqual(coordinator.takePendingCaptureResumeIfFresh(), .window)
        let status = await coordinator.runUserInitiatedValidation()

        XCTAssertEqual(status, .working)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
    }

    func testHandleCapturePermissionFailureDuringPendingResumeRepairsBeforeAlert() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("same-path-repair")
        var alertCount = 0

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 26_700) },
            repairSCKAccess: { .authorized }
        )

        coordinator.armPendingCaptureResume(mode: .area)
        XCTAssertEqual(coordinator.takePendingCaptureResumeIfFresh(), .area)
        await coordinator.handleCapturePermissionFailure()

        XCTAssertEqual(alertCount, 0)
        XCTAssertEqual(coordinator.permissionUIModel.status, .working)
    }

    func testPendingCaptureResumeTTLIsSingleUse() {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var currentTime = Date(timeIntervalSince1970: 27_000)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { PermissionTestHelpers.makeIdentity("pending-resume") },
            statusMessageSink: { _ in },
            now: { currentTime }
        )

        coordinator.armPendingCaptureResume(mode: .fullscreen)
        XCTAssertEqual(coordinator.takePendingCaptureResumeIfFresh(), .fullscreen)
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())

        currentTime = currentTime.addingTimeInterval(200)
        coordinator.armPendingCaptureResume(mode: .area)
        currentTime = currentTime.addingTimeInterval(121)
        XCTAssertNil(coordinator.takePendingCaptureResumeIfFresh())
    }

    private func makeAdvancingNow(start: TimeInterval, step: TimeInterval) -> () -> Date {
        var current = start
        return {
            defer { current += step }
            return Date(timeIntervalSince1970: current)
        }
    }

}
