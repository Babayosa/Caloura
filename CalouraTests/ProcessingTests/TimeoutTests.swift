import XCTest
@testable import Caloura

final class TimeoutTests: XCTestCase {
    func testWithTimeoutReturnsBeforeNonCancellableOperationFinishes() async {
        let releaseGate = AsyncGate()
        let started = expectation(description: "operation started")

        let start = Date()
        do {
            _ = try await withTimeout(seconds: 0.01) {
                started.fulfill()
                await releaseGate.wait()
                return "late"
            }
            XCTFail("Expected timeout")
        } catch is TimeoutError {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 0.5)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [started], timeout: 1.0)
        await releaseGate.open()
    }

    func testWithTimeoutReturnsValueWhenOperationCompletesInTime() async throws {
        let value = try await withTimeout(seconds: 5) { () -> Int? in
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testWithTimeoutPropagatesOperationError() async {
        struct SampleError: Error, Equatable {}
        do {
            _ = try await withTimeout(seconds: 5) { () -> Int? in
                throw SampleError()
            }
            XCTFail("Expected the operation error to propagate")
        } catch is SampleError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWithTimeoutCancellationCompletesWithoutHanging() async {
        // Stress the setup window: cancelling around continuation install must
        // never strand the continuation (audit L6). A stranded continuation
        // would hang `work.value` forever, so a watchdog bounds each attempt
        // and fails loudly instead of hanging the whole suite.
        for _ in 0..<20 {
            let work = Task { () -> String? in
                try await withTimeout(seconds: 30) {
                    try? await Task.sleep(for: .seconds(30))
                    return "late"
                }
            }
            work.cancel()

            let completed = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    _ = try? await work.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }

            XCTAssertTrue(
                completed,
                "withTimeout must complete after cancellation, not hang"
            )
        }
    }
}
