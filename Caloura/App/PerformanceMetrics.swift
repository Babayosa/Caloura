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
}

struct PerformanceMetricSummary {
    let stage: PerformanceMetricStage
    let sampleCount: Int
    let latestMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
}

struct PerformanceMetricsAggregator {
    private var samples: [PerformanceMetricStage: [Double]] = [:]
    private let maxSamplesPerStage: Int
    private let reportInterval: Int

    init(maxSamplesPerStage: Int = 120, reportInterval: Int = 20) {
        self.maxSamplesPerStage = max(20, maxSamplesPerStage)
        self.reportInterval = max(5, reportInterval)
    }

    mutating func record(stage: PerformanceMetricStage, milliseconds: Double) -> PerformanceMetricSummary? {
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }

        var stageSamples = samples[stage] ?? []
        stageSamples.append(milliseconds)
        if stageSamples.count > maxSamplesPerStage {
            stageSamples.removeFirst(stageSamples.count - maxSamplesPerStage)
        }
        samples[stage] = stageSamples

        guard stageSamples.count % reportInterval == 0 else { return nil }
        return PerformanceMetricSummary(
            stage: stage,
            sampleCount: stageSamples.count,
            latestMilliseconds: milliseconds,
            p50Milliseconds: percentile(0.50, values: stageSamples),
            p95Milliseconds: percentile(0.95, values: stageSamples)
        )
    }

    private func percentile(_ percentile: Double, values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int(Double(sorted.count - 1) * clamped)
        return sorted[index]
    }
}
