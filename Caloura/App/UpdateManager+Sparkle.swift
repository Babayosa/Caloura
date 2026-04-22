import Combine
@preconcurrency import Sparkle

@MainActor
final class SparkleUpdateController: UpdateControlling {
    private let controller: SPUStandardUpdaterController

    init(delegate: SPUUpdaterDelegate & SPUStandardUserDriverDelegate) {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .eraseToAnyPublisher()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class UpdateDelegateHandler: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    // Closures are stored directly on the instance (no static dispatcher
    // dictionary). The Sparkle delegate methods are `nonisolated` so they
    // can be invoked from any thread, but each one captures `self` strongly
    // into the MainActor Task it dispatches. That keeps the handler alive
    // until every in-flight callback has been delivered, eliminating the
    // prior race where a callback scheduled while the delegate was alive
    // could silently no-op because deinit + a removal-Task ran first. The
    // owners (see UpdateManager+Shared) capture `[weak box]` inside the
    // closures, so the strong self-capture creates no retain cycle back
    // to UpdateManager.
    private let onUpdateFound: (String?) -> Void
    private let onNoUpdateFound: (UpdateState) -> Void
    private let onUpdateDismissed: () -> Void
    private let onUpdateFailed: (UpdateState) -> Void
    private let onUpdateCycleFinished: (UpdateState?) -> Void

    init(
        onUpdateFound: @escaping (String?) -> Void,
        onNoUpdateFound: @escaping (UpdateState) -> Void,
        onUpdateDismissed: @escaping () -> Void,
        onUpdateFailed: @escaping (UpdateState) -> Void,
        onUpdateCycleFinished: @escaping (UpdateState?) -> Void
    ) {
        self.onUpdateFound = onUpdateFound
        self.onNoUpdateFound = onNoUpdateFound
        self.onUpdateDismissed = onUpdateDismissed
        self.onUpdateFailed = onUpdateFailed
        self.onUpdateCycleFinished = onUpdateCycleFinished
        super.init()
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        let displayVersion = item.displayVersionString
        Task { @MainActor in
            self.onUpdateFound(displayVersion)
        }
    }

    nonisolated func updaterDidNotFindUpdate(
        _ updater: SPUUpdater,
        error: any Error
    ) {
        let state = UpdateStateClassifier.classifyNoUpdate(UpdateErrorSnapshot(error: error))
        Task { @MainActor in
            self.onNoUpdateFound(state)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didDismissUpdateAlertPermanently permanently: Bool,
        for item: SUAppcastItem
    ) {
        Task { @MainActor in
            self.onUpdateDismissed()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: Error
    ) {
        let state = UpdateStateClassifier.classifyFailure(UpdateErrorSnapshot(error: error))
        Task { @MainActor in
            self.onUpdateFailed(state)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        let finalState = UpdateStateClassifier.classifyCycleResult(
            error.map(UpdateErrorSnapshot.init(error:))
        )
        Task { @MainActor in
            self.onUpdateCycleFinished(finalState)
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }
}
