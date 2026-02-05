import Foundation
import SwiftUI
import os.log

private let historyLogger = Logger(subsystem: "com.caloura.app", category: "HistoryUI")

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var performanceMetrics = PerformanceMetricsAggregator(
        maxSamplesPerStage: 120, reportInterval: 20
    )

    func show(appState: AppState) {
        let openStart = CFAbsoluteTimeGetCurrent()
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let historyView = HistoryView(appState: appState)
        let hostingView = NSHostingView(rootView: historyView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Caloura History"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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

        // Clean up when user closes via title bar to prevent window/view leak
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                if let token = self?.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.closeObserver = nil
                }
            }
        }

        self.window = window
    }
}
