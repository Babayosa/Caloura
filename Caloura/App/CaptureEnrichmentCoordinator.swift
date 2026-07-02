import Foundation

actor CaptureEnrichmentCoordinator {
    typealias Operation = @Sendable () async -> Void

    private let maxConcurrentJobs: Int
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingOrder: [UUID] = []
    private var pendingOperations: [UUID: Operation] = [:]

    init(maxConcurrentJobs: Int = 2) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
    }

    func enqueue(
        screenshotID: UUID,
        operation: @escaping Operation
    ) {
        // Queue membership is tracked by `pendingOperations`: append to the
        // order only when there is no pending op yet for this id (coalesce
        // repeat enqueues into one slot with the latest operation). This holds
        // even when the id is currently running — the re-enqueued op stays
        // pending and `scheduleIfNeeded` defers it until the in-flight run ends,
        // instead of orphaning it outside `pendingOrder` (audit L7).
        if pendingOperations[screenshotID] == nil {
            pendingOrder.append(screenshotID)
        }
        pendingOperations[screenshotID] = operation
        scheduleIfNeeded()
    }

    func cancelAll() {
        pendingOrder.removeAll()
        pendingOperations.removeAll()
        for task in runningTasks.values {
            task.cancel()
        }
        runningTasks.removeAll()
    }

    private func scheduleIfNeeded() {
        var index = 0
        while runningTasks.count < maxConcurrentJobs, index < pendingOrder.count {
            let nextID = pendingOrder[index]
            // Never run two operations for the same screenshot concurrently:
            // leave this id in place and try the next one. `finish` re-runs the
            // scheduler when the in-flight run for this id completes.
            if runningTasks[nextID] != nil {
                index += 1
                continue
            }
            pendingOrder.remove(at: index)
            guard let operation = pendingOperations.removeValue(forKey: nextID) else {
                continue
            }
            let task = Task { [weak self] in
                await operation()
                await self?.finish(screenshotID: nextID)
            }
            runningTasks[nextID] = task
        }
    }

    private func finish(screenshotID: UUID) {
        runningTasks[screenshotID] = nil
        scheduleIfNeeded()
    }
}
