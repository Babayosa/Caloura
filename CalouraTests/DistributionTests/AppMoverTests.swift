import XCTest
@testable import Caloura

/// Phase 3.3 tests for `AppMover.performMove` rollback paths.
///
/// `performMove` is exposed for tests via the `Hooks` injection seam so we can
/// drive every branch (trash → copy → verify → relaunch) without touching the
/// real filesystem or NSApplication.
@MainActor
final class AppMoverTests: XCTestCase {

    private struct StubError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { label }
    }

    /// Records every hook invocation so tests can assert ordering and
    /// rollback behavior without sharing mutable state across closures.
    private final class Recorder {
        var fileExistsCalls: [String] = []
        var trashCalls: [URL] = []
        var copyCalls: [(String, String)] = []
        var moveCalls: [(URL, URL)] = []
        var removeCalls: [URL] = []
        var launchCalls: [URL] = []
        var terminateCount = 0
    }

    private func makeHooks(
        recorder: Recorder,
        destinationExists: Bool = false,
        verificationPasses: Bool = true,
        trashResult: Result<URL?, Error> = .success(nil),
        copyResult: Result<Void, Error> = .success(()),
        moveResult: Result<Void, Error> = .success(()),
        launchResult: Result<Void, Error> = .success(())
    ) -> AppMover.Hooks {
        AppMover.Hooks(
            fileExists: { path in
                recorder.fileExistsCalls.append(path)
                if path.hasSuffix("/Caloura.app") { return destinationExists }
                if path.contains("/Contents/Info.plist") || path.contains("/Contents/MacOS/") {
                    return verificationPasses
                }
                return false
            },
            trash: { url in
                recorder.trashCalls.append(url)
                return try trashResult.get()
            },
            copy: { source, destination in
                recorder.copyCalls.append((source, destination))
                try copyResult.get()
            },
            move: { source, destination in
                recorder.moveCalls.append((source, destination))
                try moveResult.get()
            },
            remove: { url in
                recorder.removeCalls.append(url)
            },
            launch: { url in
                recorder.launchCalls.append(url)
                try launchResult.get()
            },
            terminate: {
                recorder.terminateCount += 1
            }
        )
    }

    // MARK: - Already in Applications → no-op

    func testInstallStateInApplicationsShortCircuitsMoveDecision() {
        // The public `moveToApplicationsFolder()` short-circuits when the
        // computed `currentInstallState` is `.inApplications`. We verify the
        // gate here at the level the decision is actually made.
        XCTAssertEqual(
            AppMover.installState(forBundlePath: "/Applications/Caloura.app"),
            .inApplications
        )
        XCTAssertEqual(
            AppMover.installState(forBundlePath: "/Applications/Subfolder/Caloura.app"),
            .inApplications
        )
        XCTAssertEqual(
            AppMover.installState(forBundlePath: "/Users/me/Downloads/Caloura.app"),
            .needsMoveToApplications
        )
    }

    // MARK: - Copy throws → rollback restores from trash

    func testCopyFailureRestoresPreviousCopyFromTrash() {
        let recorder = Recorder()
        let trashedURL = URL(fileURLWithPath: "/Users/me/.Trash/Caloura 2.app")
        let hooks = makeHooks(
            recorder: recorder,
            destinationExists: true,
            trashResult: .success(trashedURL),
            copyResult: .failure(StubError(label: "disk full"))
        )
        let destinationURL = URL(fileURLWithPath: "/Applications/Caloura.app")

        let result = AppMover.performMove(
            source: "/tmp/source/Caloura.app",
            destinationURL: destinationURL,
            hooks: hooks
        )

        XCTAssertEqual(result.failureMessage, "Failed to move to Applications: disk full")
        XCTAssertEqual(recorder.trashCalls.count, 1)
        XCTAssertEqual(recorder.copyCalls.count, 1)
        XCTAssertEqual(recorder.moveCalls.count, 1, "rollback must restore trashed copy")
        XCTAssertEqual(recorder.moveCalls.first?.0, trashedURL)
        XCTAssertEqual(recorder.moveCalls.first?.1, destinationURL)
        XCTAssertEqual(recorder.terminateCount, 0, "must not terminate on copy failure")
        XCTAssertEqual(recorder.launchCalls.count, 0, "must not launch on copy failure")
    }

    // MARK: - Copy succeeds, verification fails → rollback restores

    func testVerificationFailureRemovesIncompleteCopyAndRestoresFromTrash() {
        let recorder = Recorder()
        let trashedURL = URL(fileURLWithPath: "/Users/me/.Trash/Caloura 3.app")
        let hooks = makeHooks(
            recorder: recorder,
            destinationExists: true,
            verificationPasses: false,
            trashResult: .success(trashedURL),
            copyResult: .success(()),
            moveResult: .success(())
        )
        let destinationURL = URL(fileURLWithPath: "/Applications/Caloura.app")

        let result = AppMover.performMove(
            source: "/tmp/source/Caloura.app",
            destinationURL: destinationURL,
            hooks: hooks
        )

        XCTAssertEqual(
            result.failureMessage,
            "Post-copy verification failed: destination bundle is incomplete"
        )
        XCTAssertEqual(recorder.copyCalls.count, 1, "copy must run before verification")
        XCTAssertEqual(recorder.removeCalls.count, 1, "incomplete bundle must be removed")
        XCTAssertEqual(recorder.removeCalls.first, destinationURL)
        XCTAssertEqual(recorder.moveCalls.count, 1, "rollback must restore trashed copy")
        XCTAssertEqual(recorder.moveCalls.first?.0, trashedURL)
        XCTAssertEqual(recorder.moveCalls.first?.1, destinationURL)
        XCTAssertEqual(recorder.terminateCount, 0)
        XCTAssertEqual(recorder.launchCalls.count, 0)
    }

    // MARK: - Trash inaccessible mid-rollback → explicit compound error

    func testRollbackFailureSurfacesExplicitlyInsteadOfSilentlyLeaking() {
        let recorder = Recorder()
        let trashedURL = URL(fileURLWithPath: "/Users/me/.Trash/Caloura 4.app")
        let hooks = makeHooks(
            recorder: recorder,
            destinationExists: true,
            trashResult: .success(trashedURL),
            copyResult: .failure(StubError(label: "disk full")),
            moveResult: .failure(StubError(label: "trash unreachable"))
        )
        let destinationURL = URL(fileURLWithPath: "/Applications/Caloura.app")

        let result = AppMover.performMove(
            source: "/tmp/source/Caloura.app",
            destinationURL: destinationURL,
            hooks: hooks
        )

        guard let message = result.failureMessage else {
            XCTFail("expected .moveFailed, got \(result)")
            return
        }
        XCTAssertTrue(
            message.contains("disk full"),
            "compound error must include original copy failure: \(message)"
        )
        XCTAssertTrue(
            message.contains("trash unreachable"),
            "compound error must include rollback failure: \(message)"
        )
        XCTAssertTrue(
            message.contains("rollback also failed"),
            "compound error must label the rollback failure explicitly: \(message)"
        )
        XCTAssertEqual(recorder.terminateCount, 0)
    }

    // MARK: - Trash itself fails → fail fast, no copy attempt

    func testTrashFailureBeforeCopyReturnsMoveFailedAndSkipsCopy() {
        let recorder = Recorder()
        let hooks = makeHooks(
            recorder: recorder,
            destinationExists: true,
            trashResult: .failure(StubError(label: "trash denied")),
            copyResult: .success(())
        )

        let result = AppMover.performMove(
            source: "/tmp/source/Caloura.app",
            destinationURL: URL(fileURLWithPath: "/Applications/Caloura.app"),
            hooks: hooks
        )

        XCTAssertEqual(
            result.failureMessage,
            "Failed to move to Applications: trash denied"
        )
        XCTAssertEqual(recorder.copyCalls.count, 0, "must not copy when trashing failed")
        XCTAssertEqual(recorder.moveCalls.count, 0, "no rollback when there's nothing trashed")
    }
}
