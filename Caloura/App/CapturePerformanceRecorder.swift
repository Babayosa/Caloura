import Foundation
import os

struct CapturePerformanceSummary {
    let mode: CaptureMode
    let event: CapturePerformanceRecorder.Event
    let sampleCount: Int
    let latestMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
}

@MainActor
final class CapturePerformanceRecorder {
    enum Event: String, CaseIterable {
        case appActivated = "app_activated"
        case overlayVisible = "overlay_visible"
        case pickerVisibleWarm = "picker_visible_warm"
        case pickerVisibleCold = "picker_visible_cold"
        case firstInteraction = "first_interaction"
        case screenshotDuration = "screenshot_duration"
        case rawPreviewVisible = "raw_preview_visible"
        case saveComplete = "save_complete"
        case clipboardComplete = "clipboard_complete"
        case sessionComplete = "session_complete"
    }

    struct Session: Hashable {
        fileprivate let id: UUID
    }

    private struct MetricKey: Hashable {
        let mode: CaptureMode
        let event: Event
    }

    private struct SessionState {
        let mode: CaptureMode
        let startedAt: CFAbsoluteTime
        let signpostID: OSSignpostID
        let intervalState: OSSignpostIntervalState
    }

    static let shared = CapturePerformanceRecorder()

    private let logger = Logger(
        subsystem: "com.caloura.app",
        category: "CaptureTimeline"
    )
    private let signposter: OSSignposter
    private let maxSamplesPerKey: Int
    private let reportInterval: Int
    private var sessions: [UUID: SessionState] = [:]
    private var samples: [MetricKey: [Double]] = [:]

    init(maxSamplesPerKey: Int = 120, reportInterval: Int = 20) {
        self.maxSamplesPerKey = max(20, maxSamplesPerKey)
        self.reportInterval = max(5, reportInterval)
        self.signposter = OSSignposter(logger: logger)
    }

    func beginSession(mode: CaptureMode) -> Session {
        let id = UUID()
        let signpostID = signposter.makeSignpostID()
        let intervalState = signposter.beginInterval(
            "capture_session",
            id: signpostID,
            "\(mode.rawValue, privacy: .public)"
        )
        sessions[id] = SessionState(
            mode: mode,
            startedAt: CFAbsoluteTimeGetCurrent(),
            signpostID: signpostID,
            intervalState: intervalState
        )
        logger.info("capture_timeline session_started mode=\(mode.rawValue, privacy: .public)")
        return Session(id: id)
    }

    func mark(_ event: Event, in session: Session) {
        guard let state = sessions[session.id] else { return }
        let elapsed = elapsedMilliseconds(since: state.startedAt)
        signposter.emitEvent(
            "capture_event",
            id: state.signpostID,
            "mode=\(state.mode.rawValue, privacy: .public) event=\(event.rawValue, privacy: .public) ms=\(elapsed, privacy: .public)"
        )
        logger.info(
            "capture_timeline mode=\(state.mode.rawValue, privacy: .public) event=\(event.rawValue, privacy: .public) ms=\(elapsed, privacy: .public)"
        )
        record(mode: state.mode, event: event, milliseconds: elapsed)
    }

    func recordDuration(
        _ event: Event,
        milliseconds: Double,
        in session: Session
    ) {
        guard let state = sessions[session.id],
              milliseconds.isFinite,
              milliseconds >= 0 else {
            return
        }

        signposter.emitEvent(
            "capture_event",
            id: state.signpostID,
            "mode=\(state.mode.rawValue, privacy: .public) event=\(event.rawValue, privacy: .public) duration_ms=\(milliseconds, privacy: .public)"
        )
        logger.info(
            "capture_timeline mode=\(state.mode.rawValue, privacy: .public) event=\(event.rawValue, privacy: .public) duration_ms=\(milliseconds, privacy: .public)"
        )
        record(mode: state.mode, event: event, milliseconds: milliseconds)
    }

    func finishSession(_ session: Session) {
        guard let state = sessions.removeValue(forKey: session.id) else { return }
        let elapsed = elapsedMilliseconds(since: state.startedAt)
        record(mode: state.mode, event: .sessionComplete, milliseconds: elapsed)
        signposter.endInterval("capture_session", state.intervalState)
        logger.info(
            "capture_timeline session_finished mode=\(state.mode.rawValue, privacy: .public) ms=\(elapsed, privacy: .public)"
        )
    }

    func summary(
        for mode: CaptureMode,
        event: Event
    ) -> CapturePerformanceSummary? {
        let key = MetricKey(mode: mode, event: event)
        guard let values = samples[key], !values.isEmpty else { return nil }
        return CapturePerformanceSummary(
            mode: mode,
            event: event,
            sampleCount: values.count,
            latestMilliseconds: values.last ?? 0,
            p50Milliseconds: percentile(0.50, values: values),
            p95Milliseconds: percentile(0.95, values: values)
        )
    }

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }

    private func record(
        mode: CaptureMode,
        event: Event,
        milliseconds: Double
    ) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }

        let key = MetricKey(mode: mode, event: event)
        var stageSamples = samples[key] ?? []
        stageSamples.append(milliseconds)
        if stageSamples.count > maxSamplesPerKey {
            stageSamples.removeFirst(stageSamples.count - maxSamplesPerKey)
        }
        samples[key] = stageSamples

        guard stageSamples.count % reportInterval == 0 else { return }
        let p50 = percentile(0.50, values: stageSamples)
        let p95 = percentile(0.95, values: stageSamples)
        logger.info(
            "capture_timeline_summary mode=\(mode.rawValue, privacy: .public) event=\(event.rawValue, privacy: .public) n=\(stageSamples.count, privacy: .public) p50=\(p50, privacy: .public) p95=\(p95, privacy: .public)"
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
