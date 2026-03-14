import XCTest
@testable import Caloura

@MainActor
final class OnboardingFlowModelTests: XCTestCase {

    func testStartsOnReadyForFirstCapture() {
        let flow = OnboardingFlowModel()
        XCTAssertEqual(flow.currentState, .readyForFirstCapture)
        XCTAssertFalse(flow.isCompleted)
        XCTAssertTrue(flow.transitionIsForward)
    }

    func testTransitionToPermissionRepairMovesForward() {
        var flow = OnboardingFlowModel()
        flow.transition(to: .repairStalePermissionRecord)

        XCTAssertEqual(flow.currentState, .repairStalePermissionRecord)
        XCTAssertEqual(flow.previousState, .readyForFirstCapture)
        XCTAssertTrue(flow.transitionIsForward)
    }

    func testTransitionBackToInstallMovesBackward() {
        var flow = OnboardingFlowModel(initialState: .repairStalePermissionRecord)
        flow.transition(to: .installRequired)

        XCTAssertEqual(flow.currentState, .installRequired)
        XCTAssertEqual(flow.previousState, .repairStalePermissionRecord)
        XCTAssertFalse(flow.transitionIsForward)
    }

    func testCompletedStateIsMarkedCompleted() {
        var flow = OnboardingFlowModel(initialState: .readyForFirstCapture)
        flow.transition(to: .completed)

        XCTAssertTrue(flow.isCompleted)
    }

    func testOnboardingFlowStateMapsGrantedNeedsValidationByProgress() {
        XCTAssertEqual(
            onboardingFlowState(for: .grantedNeedsValidation, hasCompletedOnboarding: false),
            .readyForFirstCapture
        )
        XCTAssertEqual(
            onboardingFlowState(for: .grantedNeedsValidation, hasCompletedOnboarding: true),
            .repairStalePermissionRecord
        )
    }

    func testInstallStateDetectionUsesApplicationsPath() {
        XCTAssertEqual(
            AppMover.installState(forBundlePath: "/Applications/Caloura.app"),
            .inApplications
        )
        XCTAssertEqual(
            AppMover.installState(forBundlePath: "/Users/b/Downloads/Caloura.app"),
            .needsMoveToApplications
        )
    }
}
