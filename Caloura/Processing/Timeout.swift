import Foundation

private enum TimeoutResult<T: Sendable>: Sendable {
    case value(T?)
    case timeout
}

enum TimeoutError: Error, Sendable {
    case timedOut
}

/// Execute `operation` with a timeout. Throws `TimeoutError.timedOut` if the
/// timeout fires first and preserves errors thrown by `operation`.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T?
) async throws -> T? {
    try await withThrowingTaskGroup(of: TimeoutResult<T>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return .timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { return nil }
        switch result {
        case .value(let value):
            return value
        case .timeout:
            throw TimeoutError.timedOut
        }
    }
}
