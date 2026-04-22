import AppKit

extension RegionSelectionView {
    override func accessibilityLabel() -> String? {
        "Screen capture region selector"
    }

    override func accessibilityHelp() -> String? {
        "Drag to select a capture region. Press Escape to cancel."
    }

    func announceCaptureOverlay() {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Capture mode active. Drag to select a region. Press Escape to cancel.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
