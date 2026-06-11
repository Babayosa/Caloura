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

/// Bounded observation window for *negative* assertions: polls `condition`
/// and returns as soon as it becomes true, or when `window` elapses.
/// Unlike `pollUntil`, the timeout is the success path — the caller asserts
/// afterwards that the condition never occurred.
@MainActor
func pollForViolation(
    window: TimeInterval = 0.1,
    interval: TimeInterval = 0.01,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(window)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .seconds(interval))
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resumptions = waiters
        waiters.removeAll()
        for continuation in resumptions {
            continuation.resume()
        }
    }
}
