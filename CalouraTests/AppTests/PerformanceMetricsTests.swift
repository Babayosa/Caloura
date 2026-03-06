import XCTest
@testable import Caloura

final class PerformanceMetricsTests: XCTestCase {

    func testSummaryIsEmittedAtReportInterval() {
        var metrics = PerformanceMetricsAggregator(maxSamplesPerStage: 50, reportInterval: 5)
        var summary: PerformanceMetricSummary?

        for value in [10.0, 20.0, 30.0, 40.0, 50.0] {
            summary = metrics.record(stage: .capture, milliseconds: value)
        }

        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.sampleCount, 5)
        XCTAssertEqual(summary?.latestMilliseconds, 50.0)
        XCTAssertEqual(summary?.p50Milliseconds, 30.0)
        XCTAssertEqual(summary?.p95Milliseconds, 40.0)
    }

    func testSampleWindowIsBoundedByMaxSamples() {
        var metrics = PerformanceMetricsAggregator(maxSamplesPerStage: 20, reportInterval: 5)
        var latestSummary: PerformanceMetricSummary?

        for value in stride(from: 1.0, through: 40.0, by: 1.0) {
            latestSummary = metrics.record(stage: .total, milliseconds: value)
        }

        XCTAssertNotNil(latestSummary)
        XCTAssertEqual(latestSummary?.sampleCount, 20)
        XCTAssertEqual(latestSummary?.latestMilliseconds, 40.0)
        // With a retained window of 21...40, p50 index 9 -> 30.
        XCTAssertEqual(latestSummary?.p50Milliseconds, 30.0)
        // p95 index 18 -> 39.
        XCTAssertEqual(latestSummary?.p95Milliseconds, 39.0)
    }

    func testInvalidSampleDoesNotEmitSummary() {
        var metrics = PerformanceMetricsAggregator(maxSamplesPerStage: 30, reportInterval: 5)

        XCTAssertNil(metrics.record(stage: .process, milliseconds: -1))
        XCTAssertNil(metrics.record(stage: .process, milliseconds: .infinity))
    }

    func testStageNamesMatchPerfAuditContract() {
        XCTAssertEqual(PerformanceMetricStage.overlayVisible.rawValue, "overlay_visible")
        XCTAssertEqual(PerformanceMetricStage.total.rawValue, "total")
        XCTAssertEqual(PerformanceMetricStage.historyWindowOpen.rawValue, "history_window_open")
    }

    @MainActor
    func testCapturePerformanceRecorderSummarizesByModeAndEvent() {
        let recorder = CapturePerformanceRecorder(maxSamplesPerKey: 50, reportInterval: 5)

        for value in [10.0, 20.0, 30.0, 40.0, 50.0] {
            let session = recorder.beginSession(mode: .area)
            recorder.recordDuration(.rawPreviewVisible, milliseconds: value, in: session)
            recorder.finishSession(session)
        }

        let summary = recorder.summary(for: .area, event: .rawPreviewVisible)
        XCTAssertEqual(summary?.sampleCount, 5)
        XCTAssertEqual(summary?.latestMilliseconds, 50.0)
        XCTAssertEqual(summary?.p50Milliseconds, 30.0)
        XCTAssertEqual(summary?.p95Milliseconds, 40.0)
    }
}
