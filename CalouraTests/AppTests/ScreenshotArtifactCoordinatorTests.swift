import AppKit
import XCTest
@testable import Caloura

/// Phase 3.2 tests for `ScreenshotArtifactCoordinator`.
///
/// Cover:
/// - Concurrent `saveCapture` calls for the same id resolve to one save.
/// - `saveDerivedCapture` with `existingURL` overwrites in place.
/// - `saveDerivedCapture` without `existingURL` routes through the panel.
/// - Save failure clears the in-flight task slot.
/// - Cancellation clears the in-flight task slot.
@MainActor
final class ScreenshotArtifactCoordinatorTests: XCTestCase {

    private struct StubError: Error {}

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _saveFileCount = 0
        private var _overwriteCount = 0
        private var _promptCount = 0

        var saveFileCount: Int { lock.lock(); defer { lock.unlock() }; return _saveFileCount }
        var overwriteCount: Int { lock.lock(); defer { lock.unlock() }; return _overwriteCount }
        var promptCount: Int { lock.lock(); defer { lock.unlock() }; return _promptCount }

        func recordSaveFile() { lock.lock(); _saveFileCount += 1; lock.unlock() }
        func recordOverwrite() { lock.lock(); _overwriteCount += 1; lock.unlock() }
        func recordPrompt() { lock.lock(); _promptCount += 1; lock.unlock() }
    }

    private func makeAppState(testName: String) -> (AppState, AppSettings) {
        let suite = "com.caloura.tests.artifact.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-\(testName)-\(UUID()).json")
        let appState = AppState(defaults: defaults, historyStoreURL: temp)
        return (appState, settings)
    }

    // MARK: - saveCapture: concurrent dedup

    func testConcurrentSaveCaptureDeduplicatesToOneSaveCall() async throws {
        let (appState, settings) = makeAppState(testName: #function)
        let counter = CallCounter()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-dedup-\(UUID()).png")

        let coordinator = ScreenshotArtifactCoordinator(
            appState: appState,
            settings: settings,
            saveFile: { _, _, _, _, _ in
                counter.recordSaveFile()
                // Slow down the save so concurrent callers must wait on the
                // same in-flight task rather than racing to start their own.
                try? await Task.sleep(for: .milliseconds(50))
                return dest
            },
            overwriteImage: { _, _, _ in },
            promptForSaveURL: { _ in nil }
        )

        let processed = CapturePipelineTestHelpers.makeProcessed()

        async let url1 = coordinator.saveCapture(processed)
        async let url2 = coordinator.saveCapture(processed)
        async let url3 = coordinator.saveCapture(processed)

        let urls = try await [url1, url2, url3]

        XCTAssertEqual(urls, [dest, dest, dest])
        XCTAssertEqual(
            counter.saveFileCount, 1,
            "concurrent saves for the same id must dedupe to one underlying save"
        )
    }

    func testSaveCapturePassesTimestampOnlyFilenameSetting() async throws {
        let (appState, settings) = makeAppState(testName: #function)
        settings.timestampOnlyFileNames = true
        var capturedTimestampOnlyFileName = false
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("timestamp-only-\(UUID()).png")

        let coordinator = ScreenshotArtifactCoordinator(
            appState: appState,
            settings: settings,
            saveFile: { _, _, _, _, timestampOnlyFileName in
                capturedTimestampOnlyFileName = timestampOnlyFileName
                return dest
            },
            overwriteImage: { _, _, _ in },
            promptForSaveURL: { _ in nil }
        )

        _ = try await coordinator.saveCapture(CapturePipelineTestHelpers.makeProcessed())

        XCTAssertTrue(capturedTimestampOnlyFileName)
    }

    // MARK: - saveCapture: subsequent call after first save reuses existing URL

    func testSaveCaptureReusesExistingFilePathWithoutCallingSaveFile() async throws {
        let (appState, settings) = makeAppState(testName: #function)
        let counter = CallCounter()
        let coordinator = ScreenshotArtifactCoordinator(
            appState: appState,
            settings: settings,
            saveFile: { _, _, _, _, _ in
                counter.recordSaveFile()
                return URL(fileURLWithPath: "/should/not/be/written")
            },
            overwriteImage: { _, _, _ in },
            promptForSaveURL: { _ in nil }
        )
        let processed = CapturePipelineTestHelpers.makeProcessed()
        processed.filePath = URL(fileURLWithPath: "/tmp/already-saved.png")

        let url = try await coordinator.saveCapture(processed)
        XCTAssertEqual(url, URL(fileURLWithPath: "/tmp/already-saved.png"))
        XCTAssertEqual(counter.saveFileCount, 0, "must short-circuit when filePath already set")
    }

    // MARK: - saveCapture: failure clears in-flight slot

    func testSaveCaptureFailureClearsInFlightSlotAllowingRetry() async {
        let (appState, settings) = makeAppState(testName: #function)
        let counter = CallCounter()
        let shouldFail = ManagedAtomic(true)
        let coordinator = ScreenshotArtifactCoordinator(
            appState: appState,
            settings: settings,
            saveFile: { _, _, _, _, _ in
                counter.recordSaveFile()
                if shouldFail.value {
                    throw StubError()
                }
                return URL(fileURLWithPath: "/tmp/retry.png")
            },
            overwriteImage: { _, _, _ in },
            promptForSaveURL: { _ in nil }
        )
        let processed = CapturePipelineTestHelpers.makeProcessed()

        do {
            _ = try await coordinator.saveCapture(processed)
            XCTFail("first save should throw")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // If the in-flight slot were not cleared on failure, the second
        // call would await the dead task and propagate the same error
        // without invoking saveFile again.
        shouldFail.value = false
        do {
            let url = try await coordinator.saveCapture(processed)
            XCTAssertEqual(url, URL(fileURLWithPath: "/tmp/retry.png"))
            XCTAssertEqual(counter.saveFileCount, 2, "retry must invoke saveFile a second time")
        } catch {
            XCTFail("retry threw: \(error)")
        }
    }

    // MARK: - saveDerivedCapture: existing URL → overwrite, no panel

    func testSaveDerivedCaptureWithExistingURLOverwritesInPlace() async throws {
        let (appState, settings) = makeAppState(testName: #function)
        let counter = CallCounter()
        let existingURL = URL(fileURLWithPath: "/tmp/derived-overwrite.png")
        let coordinator = ScreenshotArtifactCoordinator(
            appState: appState,
            settings: settings,
            saveFile: { _, _, _, _, _ in
                XCTFail("saveFile must not be called for derived overwrite")
                return existingURL
            },
            overwriteImage: { _, url, _ in
                counter.recordOverwrite()
                XCTAssertEqual(url, existingURL)
            },
            promptForSaveURL: { _ in
                XCTFail("save panel must not be shown when existingURL is set")
                return nil
            }
        )
        let processed = CapturePipelineTestHelpers.makeProcessed()
        processed.filePath = existingURL
        processed.fileName = existingURL.lastPathComponent

        let updated = try await coordinator.saveDerivedCapture(
            processed.cgImage,
            basedOn: processed,
            suggestedSuffix: "redacted"
        )

        XCTAssertEqual(updated.filePath, existingURL)
        XCTAssertEqual(counter.overwriteCount, 1)
    }

    // MARK: - saveDerivedCapture: no existing URL → panel returns chosen URL

    func testSaveDerivedCaptureWithoutExistingURLPromptsAndUsesChosenURL() async throws {
        let (appState, settings) = makeAppState(testName: #function)
        let chosen = URL(fileURLWithPath: "/tmp/derived-prompted.png")
        let counter = CallCounter()
        let coordinator = ScreenshotArtifactCoordinator(
            appState: appState,
            settings: settings,
            saveFile: { _, _, _, _, _ in chosen },
            overwriteImage: { _, url, _ in
                counter.recordOverwrite()
                XCTAssertEqual(url, chosen)
            },
            promptForSaveURL: { _ in
                counter.recordPrompt()
                return chosen
            }
        )
        let processed = CapturePipelineTestHelpers.makeProcessed()
        // No filePath set → panel path is taken.

        let updated = try await coordinator.saveDerivedCapture(
            processed.cgImage,
            basedOn: processed,
            suggestedSuffix: "redacted"
        )

        XCTAssertEqual(updated.filePath, chosen)
        XCTAssertEqual(counter.promptCount, 1)
        XCTAssertEqual(counter.overwriteCount, 1)
    }

    // MARK: - saveDerivedCapture: panel cancelled → CancellationError

    func testSaveDerivedCaptureCancelledPanelThrowsCancellation() async {
        let (appState, settings) = makeAppState(testName: #function)
        let coordinator = ScreenshotArtifactCoordinator(
            appState: appState,
            settings: settings,
            saveFile: { _, _, _, _, _ in URL(fileURLWithPath: "/never") },
            overwriteImage: { _, _, _ in
                XCTFail("overwriteImage must not be called when panel is cancelled")
            },
            promptForSaveURL: { _ in nil }
        )
        let processed = CapturePipelineTestHelpers.makeProcessed()

        do {
            _ = try await coordinator.saveDerivedCapture(
                processed.cgImage,
                basedOn: processed,
                suggestedSuffix: "redacted"
            )
            XCTFail("must throw CancellationError when panel returns nil")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// Minimal lock-protected box, scoped to this test file.
final class ManagedAtomic<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { self._value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
