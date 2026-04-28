import AppKit

@MainActor
enum CaptureCursorStyle {
    static let transparentCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1)),
        hotSpot: .zero
    )
}
