import Foundation
import XCTest

/// Wall-clock measurement helper for the Phase 3.0 performance baseline
/// (audit `tasks/audit-2026-06-09-full.md`, findings 3.1/3.2/3.3).
///
/// These harnesses record numbers — they are NOT regression gates. Assertions
/// in the PerfBaseline* tests use only generous sanity bounds so the suite
/// stays deterministic across machines and load conditions.
///
/// Wall-clock timing is load-sensitive and adds seconds to every `swift test`
/// run for numbers nobody reads in CI, so the harness is **opt-in**: both
/// entry points call `requireOptIn()` first and throw `XCTSkip` unless
/// `CALOURA_RUN_PERF_BASELINES` is set to a truthy value. Because every
/// PerfBaseline* test funnels through `measure`/`measureAsync`, gating here
/// skips the whole family by construction — no per-test opt-in to forget
/// (audit L9).
enum PerfBaselineMeasurement {

    static let optInEnvironmentKey = "CALOURA_RUN_PERF_BASELINES"

    struct Stats {
        let iterations: Int
        let minMS: Double
        let medianMS: Double
        let meanMS: Double
        let maxMS: Double
    }

    /// Throws `XCTSkip` unless the perf-baseline opt-in env var is truthy.
    /// Public so a test can gate explicitly before doing expensive setup, but
    /// `measure`/`measureAsync` already call it so most callers need not.
    static func requireOptIn() throws {
        let raw = ProcessInfo.processInfo.environment[optInEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let raw, ["1", "true", "yes"].contains(raw) else {
            throw XCTSkip(
                "Perf baselines are opt-in; set \(optInEnvironmentKey)=1 to run them."
            )
        }
    }

    static func measure(
        warmup: Int = 1,
        iterations: Int,
        _ block: () throws -> Void
    ) throws -> Stats {
        try requireOptIn()
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
        isolation: isolated (any Actor)? = #isolation,
        _ block: () async throws -> Void
    ) async throws -> Stats {
        try requireOptIn()
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
