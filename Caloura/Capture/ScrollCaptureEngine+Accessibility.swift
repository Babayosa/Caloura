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

    func scrollToTopIfNeeded(scrollBar: AXElementHandle?) async throws {
        guard let scrollBar else {
            return
        }

        var attempts = 0
        while attempts < 120 && axScrollValue(scrollBar) > 0.005 {
            scrollDriver.scroll(by: 900)
            attempts += 1
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
