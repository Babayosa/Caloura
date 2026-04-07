import AppKit
import os.log

private let freezeLogger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")

@MainActor
final class CaptureFreezeService {
    static let shared = CaptureFreezeService()

    private let captureManager: ScreenCaptureManaging
    private let metricsRecorder: CaptureMetricsRecorder
    private let freezeSnapshotTimeoutSeconds: Double

    init(
        captureManager: ScreenCaptureManaging = ScreenCaptureManager.shared,
        metricsRecorder: CaptureMetricsRecorder = .shared,
        freezeSnapshotTimeoutSeconds: Double = 2.0
    ) {
        self.captureManager = captureManager
        self.metricsRecorder = metricsRecorder
        self.freezeSnapshotTimeoutSeconds = freezeSnapshotTimeoutSeconds
    }

    func freezeScreens(
        entryStart: CFAbsoluteTime
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
        return frozenImages
    }

    /// Capture all connected screens so every overlay has a clean frozen image
    /// and the selection path never falls back to a live SCK capture.
    /// Launches captures in parallel for lower total latency on multi-monitor setups.
    private func captureAllScreens() async -> [NSScreen: CGImage] {
        let tasks = NSScreen.screens.map { screen in
            (
                screen,
                Task<CGImage?, Never> { @MainActor [weak self] in
                    guard let self else { return nil }
                    return await self.captureFrozenSnapshot(for: screen)
                }
            )
        }
        let cancellableTasks = tasks.map(\.1)

        return await withTaskCancellationHandler {
            var result: [NSScreen: CGImage] = [:]
            for (screen, task) in tasks {
                let image = await task.value
                if let image {
                    result[screen] = image
                }
            }
            return result
        } onCancel: {
            for task in cancellableTasks {
                task.cancel()
            }
        }
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
