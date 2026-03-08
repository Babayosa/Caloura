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
            interactiveCheck: { true },
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
            interactiveCheck: { false },
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
            interactiveCheck: { true },
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
            interactiveCheck: { true },
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

    func testStaleRecordDetectionRepeatedCallsStableBanner() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        let identity = PermissionTestHelpers.makeIdentity("mismatch-stable")
        defaults.set(
            "different-fingerprint",
            forKey: "permissionLastWorkingIdentityFingerprint"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },
            alertPresenter: { _ in  },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 14_000) }
        )

        let first = await coordinator.refreshPassiveStatus()
        XCTAssertEqual(first, .staleRecord)
        XCTAssertTrue(coordinator.permissionUIModel.shouldShowStaleRecordBanner)

        for _ in 0..<10 {
            let status = await coordinator.refreshPassiveStatus()
            XCTAssertEqual(status, .staleRecord)
            XCTAssertTrue(coordinator.permissionUIModel.shouldShowStaleRecordBanner)
        }
    }

    func testHandleCapturePermissionFailureRapidCallsDedupe() async {
        let defaults = PermissionTestHelpers.makeDefaults(#function)
        var alertCount = 0
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { false },
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
}
