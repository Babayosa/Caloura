import Foundation

/// A bounded ring buffer of millisecond timing samples with nearest-rank
/// percentile queries.
///
/// Extracted so the two capture-timing recorders
/// (`PerformanceMetricsAggregator` and `CapturePerformanceRecorder`) share one
/// implementation of sample bounding + percentile math instead of maintaining
/// byte-identical copies that can silently diverge (audit M9).
struct MetricSampleWindow {
    private(set) var samples: [Double] = []
    let maxSamples: Int

    init(maxSamples: Int) {
        self.maxSamples = max(1, maxSamples)
    }

    /// Append a sample, trimming the oldest values beyond `maxSamples`.
    /// Returns the new sample count so callers can gate report intervals.
    @discardableResult
    mutating func append(_ value: Double) -> Int {
        samples.append(value)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        return samples.count
    }

    var count: Int { samples.count }
    var isEmpty: Bool { samples.isEmpty }
    var latest: Double? { samples.last }

    /// Nearest-rank percentile for `fraction` in `[0, 1]`. Returns 0 for an
    /// empty window.
    func percentile(_ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = Int(Double(sorted.count - 1) * clamped)
        return sorted[index]
    }
}

/// Shared elapsed-time helper for capture timing. Both recorders previously
/// duplicated `(CFAbsoluteTimeGetCurrent() - start) * 1000` independently (M9).
enum CaptureTiming {
    static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }
}
