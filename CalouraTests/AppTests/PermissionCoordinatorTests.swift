import Foundation
import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorTests: XCTestCase {

    private func makeDefaults(_ testName: String) -> UserDefaults {
        let suite = "com.caloura.tests.permission.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeIdentity(_ suffix: String) -> PermissionIdentity {
        PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/tmp/Caloura-\(suffix).app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "apple-development",
            designatedRequirementHash: "hash-\(suffix)"
        )
    }

    func testRefreshPassiveStatusDeniedWhenCGNotGranted() {
        let defaults = makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { true },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("denied") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let status = coordinator.refreshPassiveStatus()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(coordinator.permissionUIModel.status, .denied)
    }

    func testMismatchDetectionAndBannerSuppression() {
        let defaults = makeDefaults(#function)
        let identity = makeIdentity("mismatch")
        defaults.set("different-fingerprint", forKey: "permissionLastWorkingIdentityFingerprint")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let firstStatus = coordinator.refreshPassiveStatus()
        XCTAssertEqual(firstStatus, .signatureMismatch)
        XCTAssertTrue(coordinator.permissionUIModel.shouldShowSignatureMismatchBanner)

        coordinator.markCurrentMismatchBannerShown()
        _ = coordinator.refreshPassiveStatus()
        XCTAssertFalse(coordinator.permissionUIModel.shouldShowSignatureMismatchBanner)
    }

    func testCaptureFailureAlertIsDedupedByCooldown() {
        let defaults = makeDefaults(#function)
        var alertCount = 0
        var statusMessage = ""
        var now = Date(timeIntervalSince1970: 3_000)

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { false },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("cooldown") },
            statusMessageSink: { statusMessage = $0 },
            now: { now }
        )

        coordinator.handleCapturePermissionFailure()
        coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 1)
        XCTAssertFalse(statusMessage.isEmpty)

        now = now.addingTimeInterval(50)
        coordinator.handleCapturePermissionFailure()
        XCTAssertEqual(alertCount, 2)
    }

    func testUserInitiatedValidationTransitions() async {
        let defaults = makeDefaults(#function)
        var interactiveAuthorized = false

        let firstIdentity = makeIdentity("primary")
        let firstCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { interactiveAuthorized },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { firstIdentity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_000) }
        )

        let firstStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(firstStatus, .grantedNeedsRelaunch)

        interactiveAuthorized = true
        let secondStatus = await firstCoordinator.runUserInitiatedValidation()
        XCTAssertEqual(secondStatus, .grantedWorking)

        let mismatchCoordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("secondary") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 4_100) }
        )

        let mismatchStatus = mismatchCoordinator.refreshPassiveStatus()
        XCTAssertEqual(mismatchStatus, .signatureMismatch)
    }
}
