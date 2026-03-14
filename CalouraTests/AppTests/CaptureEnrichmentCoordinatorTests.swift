import XCTest
@testable import Caloura

final class CaptureEnrichmentCoordinatorTests: XCTestCase {

    func testEnqueue_preservesFIFOOrderWhenLimitedToOneWorker() async {
        let coordinator = CaptureEnrichmentCoordinator(maxConcurrentJobs: 1)
        let log = CoordinatorEventLog()
        let firstStarted = expectation(description: "first started")
        let firstFinished = expectation(description: "first finished")
        let secondStarted = expectation(description: "second started")
        let secondFinished = expectation(description: "second finished")
        let releaseFirst = AsyncGate()
        let firstID = UUID()
        let secondID = UUID()

        await coordinator.enqueue(screenshotID: firstID) {
            await log.append("start:first")
            firstStarted.fulfill()
            await releaseFirst.wait()
            await log.append("finish:first")
            firstFinished.fulfill()
        }
        await coordinator.enqueue(screenshotID: secondID) {
            await log.append("start:second")
            secondStarted.fulfill()
            await log.append("finish:second")
            secondFinished.fulfill()
        }

        await fulfillment(of: [firstStarted], timeout: 1.0)
        let initialEvents = await log.snapshot()
        XCTAssertEqual(initialEvents, ["start:first"])

        await releaseFirst.open()

        await fulfillment(
            of: [firstFinished, secondStarted, secondFinished],
            timeout: 1.0
        )
        let completedEvents = await log.snapshot()
        XCTAssertEqual(
            completedEvents,
            ["start:first", "finish:first", "start:second", "finish:second"]
        )
    }

    func testEnqueue_limitsConcurrentJobs() async {
        let coordinator = CaptureEnrichmentCoordinator(maxConcurrentJobs: 2)
        let tracker = ConcurrencyTracker()
        let twoStarted = expectation(description: "first two started")
        twoStarted.expectedFulfillmentCount = 2
        let thirdStarted = expectation(description: "third started")
        let thirdFinished = expectation(description: "third finished")
        let releaseRunning = AsyncGate()
        let ids = [UUID(), UUID(), UUID()]

        await coordinator.enqueue(screenshotID: ids[0]) {
            await tracker.start("first")
            twoStarted.fulfill()
            await releaseRunning.wait()
            await tracker.finish("first")
        }
        await coordinator.enqueue(screenshotID: ids[1]) {
            await tracker.start("second")
            twoStarted.fulfill()
            await releaseRunning.wait()
            await tracker.finish("second")
        }
        await coordinator.enqueue(screenshotID: ids[2]) {
            await tracker.start("third")
            thirdStarted.fulfill()
            await tracker.finish("third")
            thirdFinished.fulfill()
        }

        await fulfillment(of: [twoStarted], timeout: 1.0)
        let startedLabels = await tracker.startedLabels()
        let maxConcurrentAtStart = await tracker.maxConcurrentSeen()
        XCTAssertEqual(startedLabels, ["first", "second"])
        XCTAssertEqual(maxConcurrentAtStart, 2)

        await releaseRunning.open()

        await fulfillment(of: [thirdStarted, thirdFinished], timeout: 1.0)
        let finalMaxConcurrent = await tracker.maxConcurrentSeen()
        XCTAssertEqual(finalMaxConcurrent, 2)
    }

    func testEnqueue_replacesPendingOperationForDuplicateScreenshotID() async {
        let coordinator = CaptureEnrichmentCoordinator(maxConcurrentJobs: 1)
        let log = CoordinatorEventLog()
        let blockerStarted = expectation(description: "blocker started")
        let replacementRan = expectation(description: "replacement ran")
        let originalRan = expectation(description: "original duplicate should not run")
        originalRan.isInverted = true
        let releaseBlocker = AsyncGate()
        let blockerID = UUID()
        let duplicateID = UUID()

        await coordinator.enqueue(screenshotID: blockerID) {
            await log.append("start:blocker")
            blockerStarted.fulfill()
            await releaseBlocker.wait()
            await log.append("finish:blocker")
        }
        await coordinator.enqueue(screenshotID: duplicateID) {
            await log.append("run:original")
            originalRan.fulfill()
        }
        await coordinator.enqueue(screenshotID: duplicateID) {
            await log.append("run:replacement")
            replacementRan.fulfill()
        }

        await fulfillment(of: [blockerStarted], timeout: 1.0)
        await releaseBlocker.open()
        await fulfillment(of: [replacementRan], timeout: 1.0)
        await fulfillment(of: [originalRan], timeout: 0.2)

        let events = await log.snapshot()
        XCTAssertEqual(
            events,
            ["start:blocker", "finish:blocker", "run:replacement"]
        )
    }

    func testCancelAll_cancelsRunningWorkAndDropsPendingOperations() async {
        let coordinator = CaptureEnrichmentCoordinator(maxConcurrentJobs: 1)
        let runningStarted = expectation(description: "running started")
        let runningCancelled = expectation(description: "running cancelled")
        let pendingRan = expectation(description: "pending should not run")
        pendingRan.isInverted = true
        let runningID = UUID()
        let pendingID = UUID()

        await coordinator.enqueue(screenshotID: runningID) {
            runningStarted.fulfill()
            while !Task.isCancelled {
                await Task.yield()
            }
            runningCancelled.fulfill()
        }
        await coordinator.enqueue(screenshotID: pendingID) {
            pendingRan.fulfill()
        }

        await fulfillment(of: [runningStarted], timeout: 1.0)
        await coordinator.cancelAll()
        await fulfillment(of: [runningCancelled], timeout: 1.0)
        await fulfillment(of: [pendingRan], timeout: 0.2)
    }

    func testFinish_startsNextPendingOperationWhenASlotOpens() async {
        let coordinator = CaptureEnrichmentCoordinator(maxConcurrentJobs: 2)
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let thirdStarted = expectation(description: "third started")
        let releaseFirst = AsyncGate()
        let releaseSecond = AsyncGate()
        let log = CoordinatorEventLog()
        let ids = [UUID(), UUID(), UUID()]

        await coordinator.enqueue(screenshotID: ids[0]) {
            await log.append("start:first")
            firstStarted.fulfill()
            await releaseFirst.wait()
            await log.append("finish:first")
        }
        await coordinator.enqueue(screenshotID: ids[1]) {
            await log.append("start:second")
            secondStarted.fulfill()
            await releaseSecond.wait()
            await log.append("finish:second")
        }
        await coordinator.enqueue(screenshotID: ids[2]) {
            await log.append("start:third")
            thirdStarted.fulfill()
            await log.append("finish:third")
        }

        await fulfillment(of: [firstStarted, secondStarted], timeout: 1.0)
        let runningEvents = await log.snapshot()
        XCTAssertEqual(Set(runningEvents), Set(["start:first", "start:second"]))
        XCTAssertEqual(runningEvents.count, 2)

        await releaseFirst.open()

        await fulfillment(of: [thirdStarted], timeout: 1.0)
        let finishedEvents = await log.snapshot()
        XCTAssertEqual(
            Set(finishedEvents),
            Set(["start:first", "start:second", "finish:first", "start:third", "finish:third"])
        )
        XCTAssertEqual(finishedEvents.count, 5)
        XCTAssertLessThan(index(of: "start:first", in: finishedEvents), index(of: "start:third", in: finishedEvents))
        XCTAssertLessThan(index(of: "start:second", in: finishedEvents), index(of: "start:third", in: finishedEvents))
        XCTAssertLessThan(index(of: "finish:first", in: finishedEvents), index(of: "start:third", in: finishedEvents))
        XCTAssertLessThan(index(of: "start:third", in: finishedEvents), index(of: "finish:third", in: finishedEvents))

        await releaseSecond.open()
    }

    private func index(of event: String, in events: [String]) -> Int {
        guard let index = events.firstIndex(of: event) else {
            XCTFail("Missing event: \(event)")
            return -1
        }
        return index
    }
}

private actor CoordinatorEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor ConcurrencyTracker {
    private var activeCount = 0
    private var maxConcurrent = 0
    private var started: [String] = []

    func start(_ label: String) {
        started.append(label)
        activeCount += 1
        maxConcurrent = max(maxConcurrent, activeCount)
    }

    func finish(_ label: String) {
        _ = label
        activeCount -= 1
    }

    func startedLabels() -> [String] {
        started
    }

    func maxConcurrentSeen() -> Int {
        maxConcurrent
    }
}
