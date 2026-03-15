import AppKit

extension ScrollCaptureEngine {
    func axScrollValue(_ scrollBar: AXElementHandle) -> Double {
        guard let value = axAttribute(scrollBar.element, kAXValueAttribute) as? NSNumber else {
            return 0
        }
        return value.doubleValue
    }

    func axAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    func scrollToTopIfNeeded(
        scrollBar: AXElementHandle?,
        viewportHeight: Int,
        session: Session
    ) async throws {
        guard let scrollBar else {
            return
        }

        let scrollStep = max(200, Int(Double(viewportHeight) * 0.8))
        let maxAttempts = max(20, 40_000 / max(1, scrollStep)) + 5
        var attempts = 0

        while attempts < maxAttempts && axScrollValue(scrollBar) > 0.005 {
            scrollDriver.scroll(by: scrollStep)
            attempts += 1
            if attempts % 5 == 0 {
                await sendProgress(
                    ProgressUpdate(
                        phase: .preparing,
                        mode: .automatic,
                        frames: 0,
                        estimatedHeight: 0,
                        status: "Scrolling to top",
                        allowManualSwitch: session.request.config.allowManualFallback
                    ),
                    session: session
                )
            }
            try await Task.sleep(nanoseconds: 18_000_000)
        }
        scrollDriver.finishGesture()
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    func initialScrollDirection(for config: Config) -> Int {
        switch config.preferredDirection {
        case .up:
            return 1
        case .auto, .down:
            return -1
        }
    }
}
