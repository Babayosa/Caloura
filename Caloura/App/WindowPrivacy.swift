import AppKit

@MainActor
extension NSWindow {
    func excludeFromScreenSharing() {
        sharingType = .none
    }
}

@MainActor
extension NSPanel {
    /// Shared configuration for Caloura's floating overlay panels: excluded
    /// from screen sharing/recording, present on every Space and over
    /// full-screen apps, never released on close (their controllers pool/retain
    /// them), and never auto-hidden when the app deactivates. Panel-specific
    /// properties (level, opacity, mouse handling) stay at each call site.
    func configureAsOverlay() {
        excludeFromScreenSharing()
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
}
