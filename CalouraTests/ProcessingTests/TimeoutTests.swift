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
}
