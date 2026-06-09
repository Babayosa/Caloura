import Sparkle
import XCTest
@testable import Caloura

@MainActor
final class UpdateManagerTests: XCTestCase {

    private func makeSettings(_ testName: String) -> AppSettings {
        let suite = "com.caloura.tests.update.\(testName)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, legacyLicenseMigration: { .notFound })
    }

    func testInit_appliesAutomaticCheckPreferenceToController() {
        let settings = makeSettings(#function)
        settings.checkForUpdatesAutomatically = false
        let controller = MockUpdateController()

        _ = UpdateManager(settings: settings, controller: controller)

        XCTAssertFalse(controller.automaticallyChecksForUpdates)
    }

    func testCheckForUpdates_setsCheckingAndCallsController() {
        let settings = makeSettings(#function)
        let controller = MockUpdateController()
        let manager = UpdateManager(settings: settings, controller: controller)

        manager.checkForUpdates()

        XCTAssertEqual(manager.state, .checking)
        XCTAssertEqual(controller.checkForUpdatesCallCount, 1)
    }

    func testRecordUpdateFound_setsAvailableState() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())

        manager.recordUpdateFound(version: "1.2.3")

        XCTAssertEqual(manager.state, .updateAvailable(version: "1.2.3"))
    }

    func testRecordNoUpdate_latestVersion_setsUpToDate() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: 1]
        )

        manager.recordNoUpdate(error)

        XCTAssertEqual(manager.state, .upToDate)
    }

    func testRecordNoUpdate_systemTooOld_setsFailure() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: 3]
        )

        manager.recordNoUpdate(error)

        XCTAssertEqual(manager.state, .failed(errorSummary: "Update requires a newer version of macOS."))
    }

    func testRecordUpdateFailure_setsFailureState() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())

        manager.recordUpdateFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed, userInfo: [
            NSLocalizedDescriptionKey: "An SSL error has occurred and a secure connection cannot be made."
        ]))

        XCTAssertEqual(
            manager.state,
            .failed(errorSummary: "Could not connect. Check your internet connection and try again.")
        )
    }

    func testControllerObservation_updatesCanCheckForUpdates() async {
        let controller = MockUpdateController()
        let manager = UpdateManager(settings: makeSettings(#function), controller: controller)

        controller.setCanCheckForUpdates(false)
        await pollUntil(timeout: 5.0) { !manager.canCheckForUpdates }

        XCTAssertFalse(manager.canCheckForUpdates)
    }

    func testSettingsChange_updatesAutomaticCheckPreferenceOnController() async {
        let settings = makeSettings(#function)
        let controller = MockUpdateController()
        let manager = UpdateManager(settings: settings, controller: controller)

        settings.checkForUpdatesAutomatically = false
        await pollUntil(timeout: 5.0) { !controller.automaticallyChecksForUpdates }

        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
    }

    func testRecordNoUpdate_unknownReason_setsUpToDate() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        let error = NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: [:])

        manager.recordNoUpdate(error)

        XCTAssertEqual(manager.state, .upToDate)
    }

    func testRecordNoUpdate_systemTooNew_setsFailure() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: 4]
        )

        manager.recordNoUpdate(error)

        XCTAssertEqual(
            manager.state,
            .failed(errorSummary: "Update metadata does not support this macOS version.")
        )
    }

    func testRecordUpdateDismissed_setsIdleState() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        manager.recordUpdateFound(version: "2.0")

        manager.recordUpdateDismissed()

        XCTAssertEqual(manager.state, .idle)
    }

    func testFinishUpdateCycle_nilWhileChecking_setsIdle() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        manager.checkForUpdates()

        manager.finishUpdateCycle(state: nil)

        XCTAssertEqual(manager.state, .idle)
    }

    func testFinishUpdateCycle_nilWhileIdle_keepsIdle() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())

        manager.finishUpdateCycle(state: nil)

        XCTAssertEqual(manager.state, .idle)
    }

    func testFinishUpdateCycle_errorMapsToUpToDate() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: 1]
        )

        manager.finishUpdateCycle(error: error)

        XCTAssertEqual(manager.state, .upToDate)
    }

    func testFinishUpdateCycle_errorMapsToFailure() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        let error = NSError(domain: "custom", code: -1, userInfo: [NSLocalizedDescriptionKey: "offline"])

        manager.finishUpdateCycle(error: error)

        XCTAssertEqual(manager.state, .failed(errorSummary: "offline"))
    }

    func testComputedPropertiesReflectCurrentState() {
        let manager = UpdateManager(settings: makeSettings(#function), controller: MockUpdateController())
        manager.recordUpdateFound(version: "3.1")

        XCTAssertTrue(manager.updateAvailable)
        XCTAssertEqual(manager.updateVersion, "3.1")
        XCTAssertNil(manager.errorSummary)

        manager.recordUpdateFailure(.failed(errorSummary: "bad feed"))

        XCTAssertFalse(manager.updateAvailable)
        XCTAssertEqual(manager.errorSummary, "bad feed")
    }

}

@MainActor
private final class MockUpdateController: UpdateControlling {
    var canCheckForUpdates: Bool {
        canCheckForUpdatesValue
    }

    var automaticallyChecksForUpdates = true

    private var canCheckForUpdatesValue = true
    private var canCheckObserver: (@MainActor (Bool) -> Void)?
    private(set) var checkForUpdatesCallCount = 0

    func observeCanCheckForUpdates(_ handler: @escaping @MainActor (Bool) -> Void) -> AnyObject? {
        canCheckObserver = handler
        handler(canCheckForUpdatesValue)
        return ObservationToken()
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func setCanCheckForUpdates(_ value: Bool) {
        canCheckForUpdatesValue = value
        canCheckObserver?(value)
    }
}

private final class ObservationToken {}
