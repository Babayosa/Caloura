import Combine
import Sparkle

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    // IUOs so all stored properties are considered initialized before `self`
    // is captured weakly in the closures passed to UpdateDelegateHandler.
    private var updaterController: SPUStandardUpdaterController!
    private var delegateHandler: UpdateDelegateHandler!

    @Published var canCheckForUpdates = false
    @Published var updateAvailable = false
    var updateVersion: String?

    private init() {
        delegateHandler = UpdateDelegateHandler(
            onUpdateFound: { [weak self] version in
                self?.updateVersion = version
                self?.updateAvailable = true
            },
            onNoUpdateFound: { [weak self] in
                self?.updateAvailable = false
                self?.updateVersion = nil
            },
            onUpdateDismissed: { [weak self] in
                self?.updateAvailable = false
                self?.updateVersion = nil
            }
        )
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegateHandler,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// MARK: - Delegate Handler

private final class UpdateDelegateHandler: NSObject, SPUUpdaterDelegate {
    let onUpdateFound: @MainActor (String?) -> Void
    let onNoUpdateFound: @MainActor () -> Void
    let onUpdateDismissed: @MainActor () -> Void

    init(
        onUpdateFound: @escaping @MainActor (String?) -> Void,
        onNoUpdateFound: @escaping @MainActor () -> Void,
        onUpdateDismissed: @escaping @MainActor () -> Void
    ) {
        self.onUpdateFound = onUpdateFound
        self.onNoUpdateFound = onNoUpdateFound
        self.onUpdateDismissed = onUpdateDismissed
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        Task { @MainActor in
            self.onUpdateFound(item.displayVersionString)
        }
    }

    nonisolated func updaterDidNotFindUpdate(
        _ updater: SPUUpdater,
        error: any Error
    ) {
        Task { @MainActor in
            self.onNoUpdateFound()
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
}
