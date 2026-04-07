import Foundation
import os.log

private let performanceLogger = Logger(subsystem: "com.caloura.app", category: "CapturePerformance")

@MainActor
final class CaptureMetricsRecorder {
    static let shared = CaptureMetricsRecorder()

    private var performanceMetrics: PerformanceMetricsAggregator

    init(
        maxSamplesPerStage: Int = 200,
        reportInterval: Int = 20
    ) {
        self.performanceMetrics = PerformanceMetricsAggregator(
            maxSamplesPerStage: maxSamplesPerStage,
            reportInterval: reportInterval
        )
    }

    func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }

    func recordMetric(stage: PerformanceMetricStage, milliseconds: Double) {
        let key = stage.rawValue
        performanceLogger.info(
            "metric_sample stage=\(key, privacy: .public) ms=\(milliseconds, privacy: .public)"
        )
        guard let summary = performanceMetrics.record(
            stage: stage, milliseconds: milliseconds
        ) else { return }
        let name = summary.stage.rawValue
        let count = summary.sampleCount
        let lat = summary.latestMilliseconds
        performanceLogger.info(
            "metric_summary \(name, privacy: .public) n=\(count, privacy: .public) latest=\(lat, privacy: .public)"
        )
        let p50 = summary.p50Milliseconds
        let p95 = summary.p95Milliseconds
        performanceLogger.info(
            "metric_percentiles \(name, privacy: .public) p50=\(p50, privacy: .public) p95=\(p95, privacy: .public)"
        )
    }
}
