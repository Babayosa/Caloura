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
    func remove(_ observer: any SCContentSharingPickerObserver)
    func present(using style: SCShareableContentStyle)
}

/// Manages window selection using Apple's system-provided `SCContentSharingPicker`.
/// This provides a native, reliable UI for selecting windows without needing
/// custom overlays or z-order manipulation.
@MainActor
final class WindowPickerManager: NSObject {
    enum Result: Sendable {
        case selected
        case cancelled
        case failedToStart
    }

    typealias PresentationScheduler = @MainActor () async -> Void

    static let shared = WindowPickerManager(picker: SystemWindowSharingPicker.shared)

    private var continuation: CheckedContinuation<Result, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var pendingFilter: SCContentFilter?
    private var sessionObserver: SessionObserver?
    private var pickSessionID: UInt = 0
    private let picker: any WindowSharingPicking
    private let timeout: Duration
    private let schedulePresentation: PresentationScheduler

    init(
        picker: any WindowSharingPicking,
        timeout: Duration = .seconds(30),
        schedulePresentation: @escaping PresentationScheduler = {
            await Task.yield()
        }
    ) {
        self.picker = picker
        self.timeout = timeout
        self.schedulePresentation = schedulePresentation
        super.init()
        // Configure picker once at init for single window selection
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = .singleWindow
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            config.excludedBundleIDs = [bundleIdentifier]
        }
        picker.defaultConfiguration = config
    }

    /// Present the system window picker and return the content filter for the selected window.
    /// Returns a typed result so startup failures are not silently treated as user cancellation.
    func pickWindow(
        onPresented: (() -> Void)? = nil
    ) async -> Result {
        if continuation != nil {
            logger.warning("pickWindow called while previous pick is pending — rejecting new request")
            return .failedToStart
        }

        pickSessionID &+= 1
        let sessionID = pickSessionID
        pendingFilter = nil
        picker.isActive = true

        return await withCheckedContinuation { newContinuation in
            self.continuation = newContinuation
            let observer = SessionObserver(sessionID: sessionID, manager: self)
            self.sessionObserver = observer
            self.picker.add(observer)
            self.presentationTask?.cancel()
            let schedulePresentation = self.schedulePresentation
            self.presentationTask = Task { @MainActor [weak self] in
                await schedulePresentation()
                guard let self, !Task.isCancelled else { return }
                guard self.pickSessionID == sessionID, self.continuation != nil else {
                    return
                }
                self.picker.present(using: .window)
                onPresented?()
            }

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: self?.timeout ?? .seconds(30))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.continuation != nil {
                    logger.warning("Window picker timed out — cancelling pending picker session")
                    self.resumeAndClear(returning: .cancelled, sessionID: sessionID)
                }
            }
        }
    }

    func captureSelectedWindow(
        using captureManager: any ScreenCaptureManaging
    ) async throws -> CGImage {
        guard let filter = pendingFilter else {
            throw CaptureError.windowUnavailable(
                reason: "Window selection expired before capture started"
            )
        }
        pendingFilter = nil
        return try await captureManager.captureWindow(filter: filter)
    }

    // MARK: - Private

    /// Safely resume the stored continuation exactly once for the expected session.
    private func resumeAndClear(returning result: Result, sessionID: UInt) {
        guard pickSessionID == sessionID else {
            logger.debug(
                "Ignoring stale picker completion for session \(sessionID, privacy: .public)"
            )
            return
        }
        presentationTask?.cancel()
        presentationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let sessionObserver {
            picker.remove(sessionObserver)
            self.sessionObserver = nil
        }
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: result)
        }
        if result != .selected {
            pendingFilter = nil
        }
        picker.isActive = false
    }

    fileprivate func handleSelection(
        filter: SCContentFilter,
        sessionID: UInt
    ) {
        guard continuation != nil else {
            logger.debug("Ignoring picker selection with no active continuation")
            return
        }
        guard pickSessionID == sessionID else {
            logger.debug(
                "Ignoring stale picker selection for session \(sessionID, privacy: .public)"
            )
            return
        }
        pendingFilter = filter
        resumeAndClear(returning: .selected, sessionID: sessionID)
    }

    fileprivate func handleCancellation(sessionID: UInt) {
        guard pickSessionID == sessionID else {
            logger.debug(
                "Ignoring stale picker cancellation for session \(sessionID, privacy: .public)"
            )
            return
        }
        resumeAndClear(returning: .cancelled, sessionID: sessionID)
    }

    fileprivate func handleStartFailure(
        sessionID: UInt,
        error: Error
    ) {
        guard pickSessionID == sessionID else {
            logger.debug(
                "Ignoring stale picker start failure for session \(sessionID, privacy: .public)"
            )
            return
        }
        let desc = String(describing: error)
        logger.error("Window picker failed to start: \(desc, privacy: .public)")
        resumeAndClear(returning: .failedToStart, sessionID: sessionID)
    }
}

private struct SelectedFilterBox: @unchecked Sendable {
    let filter: SCContentFilter
}

private final class SessionObserver: NSObject, SCContentSharingPickerObserver {
    let sessionID: UInt
    weak var manager: WindowPickerManager?

    init(sessionID: UInt, manager: WindowPickerManager) {
        self.sessionID = sessionID
        self.manager = manager
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let filterBox = SelectedFilterBox(filter: filter)
        let manager = manager
        let sessionID = sessionID
        Task { @MainActor in
            manager?.handleSelection(filter: filterBox.filter, sessionID: sessionID)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        let manager = manager
        let sessionID = sessionID
        Task { @MainActor in
            manager?.handleCancellation(sessionID: sessionID)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let manager = manager
        let sessionID = sessionID
        Task { @MainActor in
            manager?.handleStartFailure(sessionID: sessionID, error: error)
        }
    }
}
