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

final class UpdateDelegateHandler: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @MainActor
    private final class Dispatcher {
        let onUpdateFound: (String?) -> Void
        let onNoUpdateFound: (UpdateState) -> Void
        let onUpdateDismissed: () -> Void
        let onUpdateFailed: (UpdateState) -> Void
        let onUpdateCycleFinished: (UpdateState?) -> Void

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
        }
    }

    @MainActor
    private static var dispatchers: [UUID: Dispatcher] = [:]

    private let dispatcherID: UUID

    @MainActor
    init(
        onUpdateFound: @escaping (String?) -> Void,
        onNoUpdateFound: @escaping (UpdateState) -> Void,
        onUpdateDismissed: @escaping () -> Void,
        onUpdateFailed: @escaping (UpdateState) -> Void,
        onUpdateCycleFinished: @escaping (UpdateState?) -> Void
    ) {
        self.dispatcherID = UUID()
        super.init()
        Self.dispatchers[dispatcherID] = Dispatcher(
            onUpdateFound: onUpdateFound,
            onNoUpdateFound: onNoUpdateFound,
            onUpdateDismissed: onUpdateDismissed,
            onUpdateFailed: onUpdateFailed,
            onUpdateCycleFinished: onUpdateCycleFinished
        )
    }

    deinit {
        let dispatcherID = self.dispatcherID
        Task { @MainActor [dispatcherID] in
            Self.dispatchers.removeValue(forKey: dispatcherID)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        let displayVersion = item.displayVersionString
        let dispatcherID = self.dispatcherID
        Task { @MainActor [displayVersion, dispatcherID] in
            Self.dispatchers[dispatcherID]?.onUpdateFound(displayVersion)
        }
    }

    nonisolated func updaterDidNotFindUpdate(
        _ updater: SPUUpdater,
        error: any Error
    ) {
        let state = UpdateStateClassifier.classifyNoUpdate(UpdateErrorSnapshot(error: error))
        let dispatcherID = self.dispatcherID
        Task { @MainActor [dispatcherID, state] in
            Self.dispatchers[dispatcherID]?.onNoUpdateFound(state)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didDismissUpdateAlertPermanently permanently: Bool,
        for item: SUAppcastItem
    ) {
        let dispatcherID = self.dispatcherID
        Task { @MainActor [dispatcherID] in
            Self.dispatchers[dispatcherID]?.onUpdateDismissed()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: Error
    ) {
        let state = UpdateStateClassifier.classifyFailure(UpdateErrorSnapshot(error: error))
        let dispatcherID = self.dispatcherID
        Task { @MainActor [dispatcherID, state] in
            Self.dispatchers[dispatcherID]?.onUpdateFailed(state)
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
        let dispatcherID = self.dispatcherID
        Task { @MainActor [dispatcherID, finalState] in
            Self.dispatchers[dispatcherID]?.onUpdateCycleFinished(finalState)
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }
}
