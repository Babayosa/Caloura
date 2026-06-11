import Foundation

/// Wall-clock measurement helper for the Phase 3.0 performance baseline
/// (audit `tasks/audit-2026-06-09-full.md`, findings 3.1/3.2/3.3).
///
/// These harnesses record numbers — they are NOT regression gates. Assertions
/// in the PerfBaseline* tests use only generous sanity bounds so the suite
/// stays deterministic across machines and load conditions.
enum PerfBaselineMeasurement {

    struct Stats {
        let iterations: Int
        let minMS: Double
        let medianMS: Double
        let meanMS: Double
        let maxMS: Double
    }

    static func measure(
        warmup: Int = 1,
        iterations: Int,
        _ block: () throws -> Void
    ) rethrows -> Stats {
        for _ in 0..<warmup {
            try block()
        }
        var samplesMS: [Double] = []
        samplesMS.reserveCapacity(iterations)
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            let duration = try clock.measure { try block() }
            samplesMS.append(milliseconds(from: duration))
        }
        return stats(from: samplesMS)
    }

    static func measureAsync(
        warmup: Int = 1,
        iterations: Int,
        _ block: () async throws -> Void
    ) async rethrows -> Stats {
        for _ in 0..<warmup {
            try await block()
        }
        var samplesMS: [Double] = []
        samplesMS.reserveCapacity(iterations)
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            let start = clock.now
            try await block()
            samplesMS.append(milliseconds(from: clock.now - start))
        }
        return stats(from: samplesMS)
    }

    static func summary(_ label: String, _ stats: Stats) -> String {
        String(
            format: "[perf-baseline] %@ n=%d min=%.3fms median=%.3fms mean=%.3fms max=%.3fms",
            label,
            stats.iterations,
            stats.minMS,
            stats.medianMS,
            stats.meanMS,
            stats.maxMS
        )
    }

    private static func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000.0
            + Double(components.attoseconds) / 1e15
    }

    private static func stats(from samplesMS: [Double]) -> Stats {
        let sorted = samplesMS.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return Stats(
            iterations: sorted.count,
            minMS: sorted.first ?? 0,
            medianMS: sorted[sorted.count / 2],
            meanMS: mean,
            maxMS: sorted.last ?? 0
        )
    }
}
