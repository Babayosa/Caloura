import Foundation

enum TimeoutError: Error, Sendable {
    case timedOut
}

private final class TimeoutCoordinator<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T?, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func finish(_ result: Result<T?, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

/// Execute `operation` with a timeout. Throws `TimeoutError.timedOut` if the
/// timeout fires first and preserves errors thrown by `operation`. This helper
/// returns as soon as the timeout wins; if the underlying operation ignores
/// cancellation, its late result is ignored instead of holding the caller open.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T?
) async throws -> T? {
    let coordinator = TimeoutCoordinator<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            coordinator.install(continuation)
            let operationTask = Task {
                do {
                    let value = try await operation()
                    coordinator.finish(.success(value))
                } catch {
                    coordinator.finish(.failure(error))
                }
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    coordinator.finish(.failure(TimeoutError.timedOut))
                } catch {
                    coordinator.finish(.failure(error))
                }
            }
            coordinator.setTasks(
                operationTask: operationTask,
                timeoutTask: timeoutTask
            )
        }
    } onCancel: {
        coordinator.finish(.failure(CancellationError()))
    }
}
