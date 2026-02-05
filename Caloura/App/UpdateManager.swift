import Combine
import Sparkle

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private let updaterController: SPUStandardUpdaterController
    private let delegateHandler: UpdateDelegateHandler

    @Published var canCheckForUpdates = false
    @Published var updateAvailable = false
    var updateVersion: String?

    private init() {
        let handler = UpdateDelegateHandler()
        delegateHandler = handler
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: handler,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        handler.onUpdateFound = { [weak self] version in
            self?.updateVersion = version
            self?.updateAvailable = true
        }
        handler.onNoUpdateFound = { [weak self] in
            self?.updateAvailable = false
            self?.updateVersion = nil
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// MARK: - Delegate Handler

private final class UpdateDelegateHandler: NSObject, SPUUpdaterDelegate {
    var onUpdateFound: (@MainActor (String?) -> Void)?
    var onNoUpdateFound: (@MainActor () -> Void)?

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        Task { @MainActor in
            self.onUpdateFound?(item.displayVersionString)
        }
    }

    nonisolated func updaterDidNotFindUpdate(
        _ updater: SPUUpdater,
        error: any Error
    ) {
        Task { @MainActor in
            self.onNoUpdateFound?()
        }
    }
}
