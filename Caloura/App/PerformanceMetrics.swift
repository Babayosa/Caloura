import Foundation

enum PerformanceMetricStage: String {
    case freezeSnapshot = "freeze_snapshot"
    case overlayVisible = "overlay_visible"
    case firstMouseDown = "first_mouse_down"
    case capture
    case process
    case save
    case clipboard
    case total
    case historyWindowOpen = "history_window_open"
    case piiDetection = "pii_detection"
    case beautification
    case embeddingGeneration = "embedding_generation"
    case metadataGeneration = "metadata_generation"
}

struct PerformanceMetricSummary {
    let stage: PerformanceMetricStage
    let sampleCount: Int
    let latestMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
}

struct PerformanceMetricsAggregator {
    private var windows: [PerformanceMetricStage: MetricSampleWindow] = [:]
    private let maxSamplesPerStage: Int
    private let reportInterval: Int

    init(maxSamplesPerStage: Int = 120, reportInterval: Int = 20) {
        self.maxSamplesPerStage = max(20, maxSamplesPerStage)
        self.reportInterval = max(5, reportInterval)
    }

    mutating func record(stage: PerformanceMetricStage, milliseconds: Double) -> PerformanceMetricSummary? {
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }

        var window = windows[stage] ?? MetricSampleWindow(maxSamples: maxSamplesPerStage)
        let count = window.append(milliseconds)
        windows[stage] = window

        guard count % reportInterval == 0 else { return nil }
        return PerformanceMetricSummary(
            stage: stage,
            sampleCount: count,
            latestMilliseconds: milliseconds,
            p50Milliseconds: window.percentile(0.50),
            p95Milliseconds: window.percentile(0.95)
        )
    }
}
