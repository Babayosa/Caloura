import ScreenCaptureKit

/// Manages window selection using Apple's system-provided `SCContentSharingPicker`.
/// This provides a native, reliable UI for selecting windows without needing
/// custom overlays or z-order manipulation.
@MainActor
final class WindowPickerManager: NSObject, SCContentSharingPickerObserver {
    static let shared = WindowPickerManager()

    private var continuation: CheckedContinuation<SCContentFilter?, Never>?
    private let picker = SCContentSharingPicker.shared

    private override init() {
        super.init()
        picker.add(self)
        // Configure picker once at init for single window selection
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = .singleWindow
        picker.defaultConfiguration = config
    }

    /// Present the system window picker and return the content filter for the selected window.
    /// Returns `nil` if the user cancels or no window is selected.
    /// The returned filter can be used directly with `SCScreenshotManager.captureImage()`.
    func pickWindow() async -> SCContentFilter? {
        picker.isActive = true

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            picker.present(using: .window)
        }
    }

    // MARK: - SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            // Return the filter directly — no need to look up the SCWindow
            self.continuation?.resume(returning: filter)
            self.continuation = nil
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
            picker.isActive = false
        }
    }
}
