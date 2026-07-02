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
        case requestReceived = "request_received"
        case appActivated = "app_activated"
        case cursorSessionStarted = "cursor_session_started"
        case cursorPrimed = "cursor_primed"
        case overlayVisible = "overlay_visible"
        case overlayTeardown = "overlay_teardown"
        case freezeSnapshot = "freeze_snapshot"
        case prewarmComplete = "prewarm_complete"
        case pickerVisibleWarm = "picker_visible_warm"
        case pickerVisibleCold = "picker_visible_cold"
        case pickerSelectionReceived = "picker_selection_received"
        case windowCaptureComplete = "window_capture_complete"
        case firstInteraction = "first_interaction"
        case screenshotDuration = "screenshot_duration"
        case captureImageReady = "capture_image_ready"
        case previewPresentationDuration = "preview_presentation_duration"
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
    private var windows: [MetricKey: MetricSampleWindow] = [:]

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
        let elapsed = CaptureTiming.elapsedMilliseconds(since: state.startedAt)
        let summary = "mode=\(state.mode.rawValue) event=\(event.rawValue) ms=\(elapsed)"
        signposter.emitEvent(
            "capture_event",
            id: state.signpostID,
            "\(summary, privacy: .public)"
        )
        logger.info("capture_timeline \(summary, privacy: .public)")
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

        let summary = "mode=\(state.mode.rawValue) event=\(event.rawValue) duration_ms=\(milliseconds)"
        signposter.emitEvent(
            "capture_event",
            id: state.signpostID,
            "\(summary, privacy: .public)"
        )
        logger.info("capture_timeline \(summary, privacy: .public)")
        record(mode: state.mode, event: event, milliseconds: milliseconds)
    }

    func finishSession(_ session: Session) {
        guard let state = sessions.removeValue(forKey: session.id) else { return }
        let elapsed = CaptureTiming.elapsedMilliseconds(since: state.startedAt)
        record(mode: state.mode, event: .sessionComplete, milliseconds: elapsed)
        signposter.endInterval("capture_session", state.intervalState)
        let mode = state.mode.rawValue
        logger.info(
            "capture_timeline session_finished mode=\(mode, privacy: .public) ms=\(elapsed, privacy: .public)"
        )
    }

    func summary(
        for mode: CaptureMode,
        event: Event
    ) -> CapturePerformanceSummary? {
        let key = MetricKey(mode: mode, event: event)
        guard let window = windows[key], !window.isEmpty else { return nil }
        return CapturePerformanceSummary(
            mode: mode,
            event: event,
            sampleCount: window.count,
            latestMilliseconds: window.latest ?? 0,
            p50Milliseconds: window.percentile(0.50),
            p95Milliseconds: window.percentile(0.95)
        )
    }

    /// Pure predicate for whether a sample exceeds its stage budget. Stateless
    /// and `nonisolated` so it is directly testable without a stored-counter test
    /// seam or an actor hop (L13).
    nonisolated static func isBudgetViolation(event: Event, milliseconds: Double) -> Bool {
        guard let budget = budgetMilliseconds(for: event) else { return false }
        return milliseconds > budget
    }

    private func record(
        mode: CaptureMode,
        event: Event,
        milliseconds: Double
    ) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }

        let key = MetricKey(mode: mode, event: event)
        var window = windows[key] ?? MetricSampleWindow(maxSamples: maxSamplesPerKey)
        let count = window.append(milliseconds)
        windows[key] = window
        logBudgetViolationIfNeeded(
            mode: mode,
            event: event,
            milliseconds: milliseconds
        )

        guard count % reportInterval == 0 else { return }
        let p50 = window.percentile(0.50)
        let p95 = window.percentile(0.95)
        let modeValue = mode.rawValue
        let eventValue = event.rawValue
        let countValue = count
        let summary = "capture_timeline_summary mode=\(modeValue)"
            + " event=\(eventValue)"
            + " n=\(countValue)"
            + " p50=\(p50)"
            + " p95=\(p95)"
        logger.info("\(summary, privacy: .public)")
    }

    private func logBudgetViolationIfNeeded(
        mode: CaptureMode,
        event: Event,
        milliseconds: Double
    ) {
        guard let budget = Self.budgetMilliseconds(for: event),
              milliseconds > budget else {
            return
        }

        let modeValue = mode.rawValue
        let eventValue = event.rawValue
        let warning = "capture_timeline_budget_violation mode=\(modeValue)"
            + " event=\(eventValue)"
            + " ms=\(milliseconds)"
            + " budget_ms=\(budget)"
        logger.warning("\(warning, privacy: .public)")
    }

    private nonisolated static func budgetMilliseconds(for event: Event) -> Double? {
        switch event {
        case .overlayVisible:
            50
        case .cursorPrimed:
            16.7
        case .overlayTeardown:
            50
        case .rawPreviewVisible:
            500
        default:
            nil
        }
    }
}
