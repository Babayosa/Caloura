import XCTest
@testable import Caloura

@MainActor
final class PresetManagerSaveFailureTests: XCTestCase {

    private struct EncodeFailure: Error {}

    private func makeIsolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "PresetManagerSaveFailureTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    func testSavePresets_encodeFailure_surfacesStatusMessage() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        var receivedMessages: [String] = []
        let originalSink = StatusMessageRouter.sink
        defer { StatusMessageRouter.sink = originalSink }
        StatusMessageRouter.sink = { receivedMessages.append($0) }

        let manager = PresetManager(
            defaults: defaults,
            encodePresets: { _ in throw EncodeFailure() }
        )
        receivedMessages.removeAll()

        manager.presets.append(CapturePreset(name: "Custom Failing Preset"))

        XCTAssertFalse(
            receivedMessages.isEmpty,
            "A preset save failure must surface a user-visible status message, not be swallowed"
        )
        XCTAssertTrue(
            receivedMessages.contains { $0.localizedCaseInsensitiveContains("preset") },
            "Status message should mention presets; got: \(receivedMessages)"
        )
    }

    func testSavePresets_encodeFailure_doesNotWriteToDefaults() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let originalSink = StatusMessageRouter.sink
        defer { StatusMessageRouter.sink = originalSink }
        StatusMessageRouter.sink = { _ in }

        let manager = PresetManager(
            defaults: defaults,
            encodePresets: { _ in throw EncodeFailure() }
        )
        manager.presets.append(CapturePreset(name: "Custom Failing Preset"))

        XCTAssertNil(
            defaults.data(forKey: "capturePresets"),
            "Failed encode must not write partial/stale data"
        )
    }

    func testSavePresets_success_persistsToInjectedDefaults() throws {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        var receivedMessages: [String] = []
        let originalSink = StatusMessageRouter.sink
        defer { StatusMessageRouter.sink = originalSink }
        StatusMessageRouter.sink = { receivedMessages.append($0) }

        let manager = PresetManager(defaults: defaults)
        receivedMessages.removeAll()

        manager.presets.append(CapturePreset(name: "Persisted Preset"))

        let data = try XCTUnwrap(defaults.data(forKey: "capturePresets"))
        let decoded = try JSONDecoder().decode([CapturePreset].self, from: data)
        XCTAssertTrue(decoded.contains { $0.name == "Persisted Preset" })
        XCTAssertTrue(
            receivedMessages.isEmpty,
            "Successful saves must not emit failure status messages"
        )
    }
}
