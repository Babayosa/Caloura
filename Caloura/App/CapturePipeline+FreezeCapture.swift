import AppKit
import os.log

private let freezeLogger = Logger(subsystem: "com.caloura.app", category: "CapturePipeline")

extension CapturePipeline {
    func freezeScreens(
        entryStart: CFAbsoluteTime
    ) async -> [NSScreen: CGImage] {
        let freezeStart = CFAbsoluteTimeGetCurrent()
        let frozenImages = await captureAllScreens()
        let freezeDuration = self.elapsedMilliseconds(since: freezeStart)
        let screenCount = frozenImages.count
        freezeLogger.debug(
            "Freeze pre-capture in \(freezeDuration, privacy: .public) ms (\(screenCount) screens)"
        )
        self.recordMetric(
            stage: .freezeSnapshot, milliseconds: freezeDuration
        )
        return frozenImages
    }

    /// Capture all connected screens so every overlay has a clean frozen image
    /// and the selection path never falls back to a live SCK capture.
    /// Launches captures in parallel for lower total latency on multi-monitor setups.
    func captureAllScreens() async -> [NSScreen: CGImage] {
        let screens = NSScreen.screens
        let tasks = screens.map { screen in
            (screen, Task { try? await captureManager.captureFullScreen(screen: screen) })
        }
        var result: [NSScreen: CGImage] = [:]
        for (screen, task) in tasks {
            if let image = await task.value {
                result[screen] = image
            }
        }
        return result
    }

}
