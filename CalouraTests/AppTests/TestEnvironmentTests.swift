import XCTest
@testable import Caloura

final class TestEnvironmentTests: XCTestCase {

    func testDetectsXCTestViaConfigurationFilePath() {
        XCTAssertTrue(TestEnvironment.detectXCTest(
            environment: ["XCTestConfigurationFilePath": "/tmp/config"],
            xcTestCaseClassPresent: false
        ))
    }

    func testDetectsXCTestViaBundlePath() {
        XCTAssertTrue(TestEnvironment.detectXCTest(
            environment: ["XCTestBundlePath": "/tmp/bundle.xctest"],
            xcTestCaseClassPresent: false
        ))
    }

    func testDetectsXCTestViaSessionIdentifier() {
        XCTAssertTrue(TestEnvironment.detectXCTest(
            environment: ["XCTestSessionIdentifier": "ABC"],
            xcTestCaseClassPresent: false
        ))
    }

    func testDetectsXCTestViaLoadedTestCaseClass() {
        XCTAssertTrue(TestEnvironment.detectXCTest(
            environment: [:],
            xcTestCaseClassPresent: true
        ))
    }

    func testProductionEnvironmentNotDetectedAsTestHost() {
        XCTAssertFalse(TestEnvironment.detectXCTest(
            environment: ["PATH": "/usr/bin", "HOME": "/Users/x"],
            xcTestCaseClassPresent: false
        ))
    }

    func testCurrentTestProcessIsDetected() {
        // The real composed value must be true inside any XCTest run; this is
        // the live guarantee that keeps AppMover/onboarding side effects from
        // firing in a test host.
        XCTAssertTrue(TestEnvironment.isHostingXCTest)
    }
}
