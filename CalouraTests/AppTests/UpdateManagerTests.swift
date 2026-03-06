import Combine
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

        manager.recordUpdateFailure(NSError(domain: "network", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "The appcast could not be loaded."
        ]))

        XCTAssertEqual(manager.state, .failed(errorSummary: "The appcast could not be loaded."))
    }
}

@MainActor
private final class MockUpdateController: UpdateControlling {
    var canCheckForUpdates: Bool {
        canCheckSubject.value
    }

    var automaticallyChecksForUpdates = true
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        canCheckSubject.eraseToAnyPublisher()
    }

    private let canCheckSubject = CurrentValueSubject<Bool, Never>(true)
    private(set) var checkForUpdatesCallCount = 0

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}
