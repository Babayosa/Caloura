import Foundation
import XCTest

/// Poll a condition until it's true or timeout elapses.
/// Calls `XCTFail` with a descriptive message if the condition is still false at timeout.
@MainActor
func pollUntil(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.01,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .seconds(interval))
    }
    if !condition() {
        XCTFail("pollUntil timed out after \(timeout)s", file: file, line: line)
    }
}
