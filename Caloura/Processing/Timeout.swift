import Foundation

private enum TimeoutResult<T: Sendable>: Sendable {
    case value(T?)
    case timeout
}

/// Execute `operation` with a timeout. Returns `nil` if timeout fires first.
/// Uses typed enum internally so nil operation results don't conflict with timeout.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T?
) async -> T? {
    await withTaskGroup(of: TimeoutResult<T>.self) { group in
        group.addTask { .value(try? await operation()) }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return .timeout
        }
        for await result in group {
            group.cancelAll()
            switch result {
            case .value(let value): return value
            case .timeout: return nil
            }
        }
        return nil
    }
}
