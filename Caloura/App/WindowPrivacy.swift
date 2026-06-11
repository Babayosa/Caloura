import AppKit

@MainActor
extension NSWindow {
    func excludeFromScreenSharing() {
        sharingType = .none
    }
}
