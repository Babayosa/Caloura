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
        // entry, records the peak, sleeps briefly, then decrements. If fan-out
        // regresses to parallel, peak will exceed 1.
        actor ConcurrencyProbe {
            private(set) var peak = 0
            private var inFlight = 0

            func enter() -> Int {
                inFlight += 1
                peak = max(peak, inFlight)
                return inFlight
            }

            func exit() {
                inFlight -= 1
            }
        }

        let probe = ConcurrencyProbe()

        fake.frozenSnapshotHandler = { _ in
            _ = await probe.enter()
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            await probe.exit()
            return TestImageFactory.makeTestImage(width: 40, height: 30)
        }

        let service = CaptureFreezeService(captureManager: fake)
        _ = await service.freezeScreens(entryStart: CFAbsoluteTimeGetCurrent())

        let peak = await probe.peak
        XCTAssertEqual(
            peak,
            1,
            "Freeze captures must run sequentially (peak=\(peak)); parallel fan-out regresses scheduler churn"
        )
        XCTAssertEqual(
            fake.frozenSnapshotCalls,
            NSScreen.screens.count,
            "Every screen must be captured once"
        )
    }
}
