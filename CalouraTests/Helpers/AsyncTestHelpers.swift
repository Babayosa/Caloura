import Foundation

/// Poll a condition until it's true or timeout elapses.
@MainActor
func pollUntil(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.01,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .seconds(interval))
    }
}
