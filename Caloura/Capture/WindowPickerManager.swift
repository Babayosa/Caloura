import os.log
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "WindowPicker"
)

/// Manages window selection using Apple's system-provided `SCContentSharingPicker`.
/// This provides a native, reliable UI for selecting windows without needing
/// custom overlays or z-order manipulation.
@MainActor
final class WindowPickerManager: NSObject, SCContentSharingPickerObserver {
    static let shared = WindowPickerManager()

    private var continuation: CheckedContinuation<SCContentFilter?, Never>?
    private var timeoutTask: Task<Void, Never>?
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
        // H5: Resume any existing continuation before storing the new one
        if continuation != nil {
            logger.warning("pickWindow called while previous pick is pending — cancelling previous")
            resumeAndClear(returning: nil)
        }

        picker.isActive = true

        return await withCheckedContinuation { newContinuation in
            self.continuation = newContinuation
            picker.present(using: .window)

            // H4: Timeout safety net — resume with nil if no delegate fires
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.continuation != nil {
                    logger.warning("Window picker timed out after 30s — resuming with nil")
                    self.resumeAndClear(returning: nil)
                    self.picker.isActive = false
                }
            }
        }
    }

    // MARK: - Private

    /// Safely resume the stored continuation exactly once, cancel the timeout, and nil both out.
    private func resumeAndClear(returning filter: SCContentFilter?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: filter)
        }
    }

    // MARK: - SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            self.resumeAndClear(returning: filter)
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            self.resumeAndClear(returning: nil)
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            let desc = String(describing: error)
            logger.error("Window picker failed to start: \(desc, privacy: .public)")
            self.resumeAndClear(returning: nil)
            picker.isActive = false
        }
    }
}
