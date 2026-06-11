import SwiftUI
import os.log

private let historyLogger = Logger(subsystem: "com.caloura.app", category: "HistoryUI")

@MainActor
final class HistoryWindowController {
    private let presenter = SingleWindowPresenter<HistoryView>()
    private let metricsRecorder = CaptureMetricsRecorder(
        maxSamplesPerStage: 120, reportInterval: 20
    )

    var debugWindow: NSWindow? {
        presenter.window
    }

    func show(appState: AppState) {
        let openStart = CFAbsoluteTimeGetCurrent()

        let config = SingleWindowPresenter<HistoryView>.WindowConfig(
            title: "Caloura History",
            size: CGSize(width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            sharingType: .none
        )
        let didCreate = presenter.show(config: config, activateApp: true) {
            HistoryView(appState: appState)
        }

        guard didCreate else { return }
        OnboardingTipsController.shared.showIfNeeded(.history)

        let openMilliseconds = metricsRecorder.elapsedMilliseconds(since: openStart)
        historyLogger.debug(
            "history_window_open_ms=\(openMilliseconds, privacy: .public)"
        )
        metricsRecorder.recordMetric(
            stage: .historyWindowOpen, milliseconds: openMilliseconds
        )
    }
}
