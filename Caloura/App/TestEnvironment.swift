import Foundation

/// Detects when the current process is hosting an XCTest run (unit/system
/// test bundles injected into the app binary by `xcodebuild test`).
///
/// UI tests are NOT detected here: they launch the app as a separate process
/// driven by a runner, and use the explicit `CALOURA_UI_TEST_HOST` flag.
///
/// Why this exists: an unsigned test host once ran the full launch sequence,
/// showed real onboarding, and let `AppMover` replace the user's installed
/// /Applications/Caloura.app with the debug test host. Launch side effects
/// must be impossible inside a test run, not merely unlikely.
enum TestEnvironment {
    static let isHostingXCTest: Bool = detectXCTest(
        environment: ProcessInfo.processInfo.environment,
        xcTestCaseClassPresent: NSClassFromString("XCTestCase") != nil
    )

    static func detectXCTest(
        environment: [String: String],
        xcTestCaseClassPresent: Bool
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil ||
            xcTestCaseClassPresent
    }
}
