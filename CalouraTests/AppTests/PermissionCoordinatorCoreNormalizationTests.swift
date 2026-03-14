import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorNormalizationTests: XCTestCase {
    func testRequestPermissionFromSystemClearsExplicitDiagnosis() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("clear-diagnosis")

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { .transientFailure },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 5_175) },
            repairSCKAccess: { .transientFailure }
        )

        let validationStatus = await coordinator.runUserInitiatedValidation()
        let diagnosedRefreshStatus = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(validationStatus, .needsRelaunch)
        XCTAssertEqual(diagnosedRefreshStatus, .needsRelaunch)

        XCTAssertTrue(coordinator.requestPermissionFromSystem())

        let refreshStatus = await coordinator.refreshPassiveStatus()

        XCTAssertEqual(refreshStatus, .grantedNeedsValidation)
        XCTAssertEqual(coordinator.permissionUIModel.status, .grantedNeedsValidation)
    }
}
