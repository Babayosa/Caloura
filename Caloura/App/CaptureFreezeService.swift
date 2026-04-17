import AppKit
import os.log

private let freezeLogger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")

@MainActor
final class CaptureFreezeService {
    static let shared = CaptureFreezeService()

    private let captureManager: ScreenCaptureManaging
    private let metricsRecorder: CaptureMetricsRecorder
    private let performanceRecorder: CapturePerformanceRecorder
    private let freezeSnapshotTimeoutSeconds: Double

    init(
        captureManager: ScreenCaptureManaging = ScreenCaptureManager.shared,
        metricsRecorder: CaptureMetricsRecorder = .shared,
        performanceRecorder: CapturePerformanceRecorder = .shared,
        freezeSnapshotTimeoutSeconds: Double = 2.0
    ) {
        self.captureManager = captureManager
        self.metricsRecorder = metricsRecorder
        self.performanceRecorder = performanceRecorder
        self.freezeSnapshotTimeoutSeconds = freezeSnapshotTimeoutSeconds
    }

    func freezeScreens(
        entryStart: CFAbsoluteTime,
        performanceSession: CapturePerformanceRecorder.Session? = nil
    ) async -> [NSScreen: CGImage] {
        let freezeStart = CFAbsoluteTimeGetCurrent()
        let frozenImages = await captureAllScreens()
        let freezeDuration = metricsRecorder.elapsedMilliseconds(since: freezeStart)
        let screenCount = frozenImages.count
        freezeLogger.debug(
            "Freeze pre-capture in \(freezeDuration, privacy: .public) ms (\(screenCount) screens)"
        )
        metricsRecorder.recordMetric(
            stage: .freezeSnapshot, milliseconds: freezeDuration
        )
        if let performanceSession {
            performanceRecorder.recordDuration(
                .freezeSnapshot,
                milliseconds: freezeDuration,
                in: performanceSession
            )
        }
        return frozenImages
    }

    /// Capture all connected screens so every overlay has a clean frozen image
    /// and the selection path never falls back to a live SCK capture.
    ///
    /// Captures run sequentially on MainActor — the Task fan-out serialized
    /// there anyway, and the extra scheduler churn added ~3-5ms of hop noise.
    private func captureAllScreens() async -> [NSScreen: CGImage] {
        var result: [NSScreen: CGImage] = [:]
        for screen in NSScreen.screens {
            if Task.isCancelled { break }
            if let image = await captureFrozenSnapshot(for: screen) {
                result[screen] = image
            }
        }
        return result
    }

    private func captureFrozenSnapshot(
        for screen: NSScreen
    ) async -> CGImage? {
        let captureSnapshot: @MainActor @Sendable () async throws -> CGImage? = { [captureManager] in
            try await captureManager.captureFrozenDisplaySnapshot(screen: screen)
        }

        do {
            return try await withTimeout(seconds: freezeSnapshotTimeoutSeconds) {
                try await captureSnapshot()
            }
        } catch is CancellationError {
            freezeLogger.debug(
                "Freeze snapshot cancelled for \(screen.localizedName, privacy: .public)"
            )
            return nil
        } catch is TimeoutError {
            let timeoutSeconds = self.freezeSnapshotTimeoutSeconds
            let logMessage = "Freeze snapshot timed out for \(screen.localizedName) "
                + "after \(timeoutSeconds)s"
            freezeLogger.warning(
                "\(logMessage, privacy: .public)"
            )
            return nil
        } catch {
            let message = error.localizedDescription
            freezeLogger.warning(
                "Freeze snapshot skipped for \(screen.localizedName, privacy: .public): \(message, privacy: .public)"
            )
            return nil
        }
    }
}
