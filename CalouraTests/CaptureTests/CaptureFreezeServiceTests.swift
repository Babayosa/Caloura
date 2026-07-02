import AppKit
import XCTest
@testable import Caloura

@MainActor
final class CaptureFreezeServiceTests: XCTestCase {

    func testFreezeScreens_runsSequentiallyNotInParallel() async throws {
        // Multi-screen parallel fan-out used to land here; the freeze path now
        // serializes on MainActor. Guarantee the contract so a regression to
        // `map { Task { … } }` gets caught immediately.

        guard NSScreen.screens.count >= 1 else {
            throw XCTSkip("Need at least one screen to exercise the freeze path")
        }

        let fake = FakeScreenCaptureManager()

        // Track concurrency: each handler increments an in-flight counter on
        // entry, records the peak, then decrements on exit. If fan-out regresses
        // to parallel, more than one handler is in flight and peak exceeds 1.
        // Lock-guarded (not an actor) so `peak` is readable synchronously inside
        // the `pollForViolation` condition below.
        final class ConcurrencyProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var _peak = 0
            private var inFlight = 0

            var peak: Int { lock.lock(); defer { lock.unlock() }; return _peak }

            func enter() {
                lock.lock()
                inFlight += 1
                _peak = max(_peak, inFlight)
                lock.unlock()
            }

            func exit() {
                lock.lock()
                inFlight -= 1
                lock.unlock()
            }
        }

        let probe = ConcurrencyProbe()
        let firstEntered = expectation(description: "first freeze handler entered")
        // A parallel regression enters every handler; only the first entry needs
        // to unblock the test, so tolerate extra fulfillments.
        firstEntered.assertForOverFulfill = false
        let release = AsyncGate()

        fake.frozenSnapshotHandler = { _ in
            probe.enter()
            firstEntered.fulfill()
            // Block on a gate instead of sleeping a fixed 20ms: correct
            // sequential execution never invokes the next handler until this one
            // returns, while a parallel fan-out lets every handler reach here and
            // raise the peak — an unbounded window with no arbitrary delay.
            await release.wait()
            probe.exit()
            return TestImageFactory.makeTestImage(width: 40, height: 30)
        }

        let service = CaptureFreezeService(captureManager: fake)
        // Discard the result inside the task so its `.value` is `Void`; the
        // freeze result (`[NSScreen: CGImage]`) is non-Sendable and cannot cross
        // the task boundary.
        let freeze = Task {
            _ = await service.freezeScreens(entryStart: CFAbsoluteTimeGetCurrent())
        }

        await fulfillment(of: [firstEntered], timeout: 1.0)

        // With the first handler provably in flight and blocked, a parallel
        // fan-out would have dispatched the remaining handlers concurrently.
        // Watch for a second concurrent entry (negative assertion): this returns
        // early if the peak ever exceeds 1, else confirms it stayed 1.
        await pollForViolation { probe.peak > 1 }
        let peak = probe.peak
        XCTAssertEqual(
            peak,
            1,
            "Freeze captures must run sequentially (peak=\(peak)); parallel fan-out regresses scheduler churn"
        )

        await release.open()
        _ = await freeze.value

        XCTAssertEqual(
            fake.frozenSnapshotCalls,
            NSScreen.screens.count,
            "Every screen must be captured once"
        )
    }
}
