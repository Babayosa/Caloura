import XCTest
@testable import Caloura

final class OnboardingFlowModelTests: XCTestCase {

    func testStartsOnPermissionStep() {
        let flow = OnboardingFlowModel()
        XCTAssertEqual(flow.currentStep, .permission)
        XCTAssertTrue(flow.isFirstStep)
        XCTAssertFalse(flow.isLastStep)
    }

    func testSkipPermissionWhenReadyMovesToFirstCapture() {
        var flow = OnboardingFlowModel()
        flow.skipPermissionIfReady(true)

        XCTAssertEqual(flow.currentStep, .firstCapture)
        XCTAssertTrue(flow.isLastStep)
    }

    func testNextMovesToFirstCapture() {
        var flow = OnboardingFlowModel()
        flow.next()

        XCTAssertEqual(flow.currentStep, .firstCapture)
    }

    func testBackReturnsToPermission() {
        var flow = OnboardingFlowModel()
        flow.next()
        flow.back()

        XCTAssertEqual(flow.currentStep, .permission)
    }
}
