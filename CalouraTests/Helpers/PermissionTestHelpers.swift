import Foundation
@testable import Caloura

/// Shared test helpers for PermissionCoordinator tests.
enum PermissionTestHelpers {

    /// Creates a clean `UserDefaults` suite for isolated test runs.
    /// The suite name includes the test name for traceability.
    static func makeDefaults(_ testName: String) -> UserDefaults {
        let suite = "com.caloura.tests.permission.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Creates a `PermissionIdentity` with a unique suffix to avoid
    /// fingerprint collisions between tests.
    static func makeIdentity(
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
}
