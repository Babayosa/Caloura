import SwiftUI
import os.log

private let historyLogger = Logger(subsystem: "com.caloura.app", category: "HistoryUI")

@MainActor
final class HistoryWindowController {
    private let presenter = SingleWindowPresenter<HistoryView>()
    private var performanceMetrics = PerformanceMetricsAggregator(
        maxSamplesPerStage: 120, reportInterval: 20
    )

    func show(appState: AppState) {
        let openStart = CFAbsoluteTimeGetCurrent()

        let config = SingleWindowPresenter<HistoryView>.WindowConfig(
            title: "Caloura History",
            size: CGSize(width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable]
        )
        let didCreate = presenter.show(config: config) {
            HistoryView(appState: appState)
        }

        guard didCreate else { return }
        OnboardingTipsController.shared.showIfNeeded(.history)

        let openMilliseconds = (CFAbsoluteTimeGetCurrent() - openStart) * 1000
        historyLogger.debug(
            "history_window_open_ms=\(openMilliseconds, privacy: .public)"
        )
        let stageName = PerformanceMetricStage.historyWindowOpen.rawValue
        let sampleMsg = "metric_sample stage=\(stageName)"
            + " ms=\(openMilliseconds)"
        historyLogger.info("\(sampleMsg, privacy: .public)")
        if let summary = performanceMetrics.record(
            stage: .historyWindowOpen, milliseconds: openMilliseconds
        ) {
            let sumStage = summary.stage.rawValue
            let sampleCount = summary.sampleCount
            let latest = summary.latestMilliseconds
            let p50 = summary.p50Milliseconds
            let p95 = summary.p95Milliseconds
            let summaryMsg = "metric_summary stage=\(sumStage)"
                + " samples=\(sampleCount)"
                + " latest_ms=\(latest)"
                + " p50_ms=\(p50)"
                + " p95_ms=\(p95)"
            historyLogger.info("\(summaryMsg, privacy: .public)")
        }
    }
}
