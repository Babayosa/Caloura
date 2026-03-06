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

    /// Capture screens for freeze mode. For multi-monitor, we freeze only the
    /// active screen to reduce latency; other screens fall back to live capture.
    func captureAllScreens() async -> [NSScreen: CGImage] {
        let screens = NSScreen.screens

        if screens.count == 1, let screen = screens.first {
            if let image = try? await captureManager.captureFullScreen(screen: screen) {
                return [screen: image]
            }
            return [:]
        }

        guard let activeScreen = screenForMouseLocation(in: screens)
                ?? NSScreen.main ?? screens.first else {
            return [:]
        }
        if let image = try? await captureManager.captureFullScreen(screen: activeScreen) {
            return [activeScreen: image]
        }
        return [:]
    }

    func screenForMouseLocation(in screens: [NSScreen]) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
    }
}
