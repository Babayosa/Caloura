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
        if pendingOperations[screenshotID] == nil,
           runningTasks[screenshotID] == nil {
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
        while runningTasks.count < maxConcurrentJobs,
              let nextID = pendingOrder.first {
            pendingOrder.removeFirst()
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
