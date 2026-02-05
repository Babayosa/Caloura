import Foundation
import XCTest
@testable import Caloura

@MainActor
final class PermissionCoordinatorEdgeCaseTests: XCTestCase {

    private func makeDefaults(_ testName: String) -> UserDefaults {
        let suite = "com.caloura.tests.permission.edge.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeIdentity(
        _ suffix: String
    ) -> PermissionIdentity {
        PermissionIdentity(
            bundleIdentifier: "com.caloura.app",
            executablePath: "/tmp/Caloura-\(suffix)"
                + ".app/Contents/MacOS/Caloura",
            teamIdentifier: "NG4ML6Q47T",
            signingIdentityType: "apple-development",
            designatedRequirementHash: "hash-\(suffix)"
        )
    }

    // MARK: - refreshPassiveStatus repeated calls

    func testRepeatedRefreshPassiveStatus_stableResult() {
        let defaults = makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { true },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("stable") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 10_000) }
        )

        // Call refreshPassiveStatus many times in rapid succession
        var results: [PermissionStatus] = []
        for _ in 0..<20 {
            let status = coordinator.refreshPassiveStatus()
            results.append(status)
        }

        // All results should be identical
        let firstResult = results[0]
        for (index, result) in results.enumerated() {
            XCTAssertEqual(
                result, firstResult,
                "Result at call \(index) differs from first call"
            )
        }
    }

    func testRepeatedRefreshPassiveStatus_deniedIsStable() {
        let defaults = makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { false },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("denied") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 11_000) }
        )

        for _ in 0..<20 {
            let status = coordinator.refreshPassiveStatus()
            XCTAssertEqual(status, .denied)
        }

        XCTAssertEqual(
            coordinator.permissionUIModel.status,
            .denied
        )
    }

    // MARK: - refreshPassiveStatus does not crash

    func testRefreshPassiveStatus_doesNotCrashWithGranted() {
        let defaults = makeDefaults(#function)
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { true },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("granted") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 12_000) }
        )

        let status = coordinator.refreshPassiveStatus()
        // Should return a valid status without crashing
        XCTAssertNotEqual(status, .unknown)
    }

    // MARK: - UI model consistency after repeated calls

    func testUIModelConsistency_afterRepeatedRefreshCalls() {
        let defaults = makeDefaults(#function)
        var callCount = 0
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { true },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("uimodel") },
            statusMessageSink: { _ in callCount += 1 },
            now: { Date(timeIntervalSince1970: 13_000) }
        )

        // Rapid-fire calls should not cause inconsistent state
        for _ in 0..<10 {
            coordinator.refreshPassiveStatus()
        }

        let model = coordinator.permissionUIModel
        // Status and banner should be consistent
        if model.status != .signatureMismatch {
            XCTAssertFalse(
                model.shouldShowSignatureMismatchBanner,
                "Banner should not show when status is not mismatch"
            )
        }
    }

    // MARK: - Mismatch detection stability

    func testMismatchDetection_repeatedCalls_stableBanner() {
        let defaults = makeDefaults(#function)
        let identity = makeIdentity("mismatch-stable")
        defaults.set(
            "different-fingerprint",
            forKey: "permissionLastWorkingIdentityFingerprint"
        )

        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { true },
            interactiveCheck: { false },
            alertPresenter: { _ in },
            permissionRequester: { true },
            identityProvider: { identity },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 14_000) }
        )

        // First call should detect mismatch
        let first = coordinator.refreshPassiveStatus()
        XCTAssertEqual(first, .signatureMismatch)
        XCTAssertTrue(
            coordinator.permissionUIModel
                .shouldShowSignatureMismatchBanner
        )

        // Subsequent calls should remain stable
        for _ in 0..<10 {
            let status = coordinator.refreshPassiveStatus()
            XCTAssertEqual(status, .signatureMismatch)
            XCTAssertTrue(
                coordinator.permissionUIModel
                    .shouldShowSignatureMismatchBanner
            )
        }
    }

    // MARK: - handleCapturePermissionFailure repeated rapid calls

    func testHandleCapturePermissionFailure_rapidCalls_dedupe() {
        let defaults = makeDefaults(#function)
        var alertCount = 0
        let coordinator = PermissionCoordinator(
            defaults: defaults,
            passiveCheck: { false },
            interactiveCheck: { false },
            alertPresenter: { _ in alertCount += 1 },
            permissionRequester: { true },
            identityProvider: { self.makeIdentity("rapid-fail") },
            statusMessageSink: { _ in },
            now: { Date(timeIntervalSince1970: 15_000) }
        )

        // Rapid calls within cooldown window should only trigger
        // one alert
        for _ in 0..<10 {
            coordinator.handleCapturePermissionFailure()
        }

        XCTAssertEqual(
            alertCount, 1,
            "Only one alert should be shown within cooldown window"
        )
    }
}
