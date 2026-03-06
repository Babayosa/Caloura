import os.log
@preconcurrency import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.caloura.app",
    category: "WindowPicker"
)

@MainActor
protocol WindowSharingPicking: AnyObject {
    var isActive: Bool { get set }
    var defaultConfiguration: SCContentSharingPickerConfiguration { get set }

    func add(_ observer: any SCContentSharingPickerObserver)
    func present(using style: SCShareableContentStyle)
}

/// Manages window selection using Apple's system-provided `SCContentSharingPicker`.
/// This provides a native, reliable UI for selecting windows without needing
/// custom overlays or z-order manipulation.
@MainActor
final class WindowPickerManager: NSObject {
    enum Result: @unchecked Sendable {
        case selected(SCContentFilter)
        case cancelled
        case failedToStart
    }

    static let shared = WindowPickerManager(picker: SystemWindowSharingPicker.shared)

    private var continuation: CheckedContinuation<Result, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let picker: any WindowSharingPicking
    private let timeout: Duration

    init(
        picker: any WindowSharingPicking,
        timeout: Duration = .seconds(30)
    ) {
        self.picker = picker
        self.timeout = timeout
        super.init()
        picker.add(self)
        // Configure picker once at init for single window selection
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = .singleWindow
        picker.defaultConfiguration = config
    }

    /// Present the system window picker and return the content filter for the selected window.
    /// Returns a typed result so startup failures are not silently treated as user cancellation.
    func pickWindow(
        onPresented: (() -> Void)? = nil
    ) async -> Result {
        if continuation != nil {
            logger.warning("pickWindow called while previous pick is pending — cancelling previous")
            resumeAndClear(returning: .cancelled)
        }

        picker.isActive = true

        return await withCheckedContinuation { newContinuation in
            self.continuation = newContinuation
            picker.present(using: .window)
            onPresented?()

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: self?.timeout ?? .seconds(30))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.continuation != nil {
                    logger.warning("Window picker timed out — cancelling pending picker session")
                    self.resumeAndClear(returning: .cancelled)
                }
            }
        }
    }

    // MARK: - Private

    /// Safely resume the stored continuation exactly once, cancel the timeout, and nil both out.
    private func resumeAndClear(returning result: Result) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: result)
        }
        picker.isActive = false
    }

}

extension WindowPickerManager: @preconcurrency SCContentSharingPickerObserver {
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        resumeAndClear(returning: .selected(filter))
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        resumeAndClear(returning: .cancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let desc = String(describing: error)
        logger.error("Window picker failed to start: \(desc, privacy: .public)")
        resumeAndClear(returning: .failedToStart)
    }
}
