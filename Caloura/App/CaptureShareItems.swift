import AppKit

/// Resolves the artifacts handed to a native share sheet (`NSSharingServicePicker`
/// / `ShareLink`). Kept as a pure, side-effect-free helper so the selection logic
/// is unit-testable without presenting any UI.
enum CaptureShareItems {
    /// Prefer the on-disk file (preserves filename + full quality); fall back to
    /// the in-memory image for a capture that hasn't been saved yet.
    static func items(for screenshot: ProcessedScreenshot) -> [Any] {
        if let filePath = screenshot.filePath {
            return [filePath]
        }
        return [screenshot.image]
    }

    /// History items are always backed by an on-disk PNG. Empty path → nothing
    /// shareable (caller should hide the affordance).
    static func items(for item: ScreenshotItem) -> [Any] {
        guard !item.filePath.isEmpty else { return [] }
        return [URL(fileURLWithPath: item.filePath)]
    }
}
