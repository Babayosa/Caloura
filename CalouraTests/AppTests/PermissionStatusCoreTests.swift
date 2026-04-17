import XCTest
@testable import Caloura

final class PermissionStatusCoreTests: XCTestCase {
    func testPassiveStatusDeniedWithoutGrantOrFreshRequest() {
        let status = PermissionStatusCore.passiveStatus(
            cgGranted: false,
            context: makeContext(hasFreshPermissionRequest: false)
        )

        XCTAssertEqual(status, .denied)
    }

    func testPassiveStatusStaysValidationNeededDuringFreshRequest() {
        let status = PermissionStatusCore.passiveStatus(
            cgGranted: false,
            context: makeContext(hasFreshPermissionRequest: true)
        )

        XCTAssertEqual(status, .grantedNeedsValidation)
    }

    func testExplicitFailureStatusTriesValidationForSamePathMismatch() {
        let status: ScreenRecordingState = PermissionStatusCore.explicitFailureStatus(
            for: makeContext(
                lastWorkingExecutablePathMatches: true,
                hasKnownWorkingMismatch: true
            )
        )

        // Same path + fingerprint mismatch = in-place update. Try validation first.
        XCTAssertEqual(status, .grantedNeedsValidation)
    }

    func testExplicitFailureStatusStaleRecordForDifferentPathMismatch() {
        let status: ScreenRecordingState = PermissionStatusCore.explicitFailureStatus(
            for: makeContext(
                lastWorkingExecutablePathMatches: false,
                hasKnownWorkingMismatch: true
            )
        )

        XCTAssertEqual(status, .staleRecord)
    }

    func testUIModelShowsStaleRecordGuidanceAndBanner() {
        let identity = PermissionTestHelpers.makeIdentity("stale-model")
        let model = PermissionStatusCore.uiModel(
            status: .staleRecord,
            context: makeContext(identity: identity),
            cooldownActive: true
        )

        XCTAssertEqual(model.status, .staleRecord)
        XCTAssertTrue(model.shouldShowStaleRecordBanner)
        XCTAssertTrue(model.isAlertCooldownActive)
        XCTAssertTrue(model.guidanceText?.contains(identity.executablePath) == true)
    }

    func testUIModelShowsWaitingGuidanceDuringFreshRequest() {
        let model = PermissionStatusCore.uiModel(
            status: .grantedNeedsValidation,
            context: makeContext(hasFreshPermissionRequest: true),
            cooldownActive: false
        )

        XCTAssertEqual(
            model.guidanceText,
            "Caloura is waiting for macOS to finish applying Screen Recording. Keep the toggle enabled and return here."
        )
        XCTAssertFalse(model.shouldShowStaleRecordBanner)
    }

    func testNonBlockingMessageForStaleRecord() {
        let message = PermissionStatusCore.nonBlockingMessage(for: .staleRecord)

        XCTAssertEqual(
            message,
            "Screen Recording appears tied to a different Caloura copy. Open /Applications/Caloura.app and try again."
        )
    }

    func testNonBlockingMessageForWorkingIsDistinctFromInitializing() {
        let working = PermissionStatusCore.nonBlockingMessage(for: .working)
        let initializing = PermissionStatusCore.nonBlockingMessage(for: .grantedNeedsValidation)

        XCTAssertEqual(working, "Screen Recording is ready.")
        XCTAssertNotEqual(working, initializing)
    }

    private func makeContext(
        identity: PermissionIdentity = PermissionTestHelpers.makeIdentity("status-core"),
        hasFreshPermissionRequest: Bool = false,
        hasLiveValidatedIdentity: Bool = false,
        isKnownWorkingIdentity: Bool = false,
        lastWorkingExecutablePathMatches: Bool = false,
        diagnosedFailureStatus: ScreenRecordingState? = nil,
        hasKnownWorkingMismatch: Bool = false,
        didAutoRelaunchAfterRequest: Bool = false
    ) -> PermissionStatusContext {
        PermissionStatusContext(
            identity: identity,
            hasFreshPermissionRequest: hasFreshPermissionRequest,
            hasLiveValidatedIdentity: hasLiveValidatedIdentity,
            isKnownWorkingIdentity: isKnownWorkingIdentity,
            lastWorkingExecutablePathMatches: lastWorkingExecutablePathMatches,
            diagnosedFailureStatus: diagnosedFailureStatus,
            hasKnownWorkingMismatch: hasKnownWorkingMismatch,
            didAutoRelaunchAfterRequest: didAutoRelaunchAfterRequest
        )
    }
}
