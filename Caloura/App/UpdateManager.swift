import Combine
import Sparkle

enum UpdateState: Equatable {
    case idle
    case checking
    case updateAvailable(version: String?)
    case upToDate
    case failed(errorSummary: String)
}

private enum SparkleNoUpdateReason: Int {
    case unknown = 0
    case onLatestVersion = 1
    case onNewerThanLatestVersion = 2
    case systemIsTooOld = 3
    case systemIsTooNew = 4
}

@MainActor
protocol UpdateControlling: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }

    func checkForUpdates()
}

@MainActor
private final class SparkleUpdateController: UpdateControlling {
    private let controller: SPUStandardUpdaterController

    init(delegate: SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
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
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private let settings: AppSettings
    private var controller: (any UpdateControlling)!
    private var delegateHandler: UpdateDelegateHandler? = nil
    private var cancellables: Set<AnyCancellable> = []

    @Published var canCheckForUpdates = false
    @Published private(set) var state: UpdateState = .idle

    var updateAvailable: Bool {
        guard case .updateAvailable = state else { return false }
        return true
    }

    var updateVersion: String? {
        guard case let .updateAvailable(version) = state else { return nil }
        return version
    }

    var errorSummary: String? {
        guard case let .failed(summary) = state else { return nil }
        return summary
    }

    private init() {
        self.settings = AppSettings.shared

        let delegateHandler = UpdateDelegateHandler(
            onUpdateFound: { [weak self] version in
                self?.recordUpdateFound(version: version)
            },
            onNoUpdateFound: { [weak self] error in
                self?.recordNoUpdate(error)
            },
            onUpdateDismissed: { [weak self] in
                self?.recordUpdateDismissed()
            },
            onUpdateFailed: { [weak self] error in
                self?.recordUpdateFailure(error)
            },
            onUpdateCycleFinished: { [weak self] error in
                self?.finishUpdateCycle(error: error)
            }
        )
        self.delegateHandler = delegateHandler
        self.controller = SparkleUpdateController(delegate: delegateHandler)

        bindController()
    }

    init(
        settings: AppSettings,
        controller: any UpdateControlling
    ) {
        self.settings = settings
        self.controller = controller
        bindController()
    }

    private func bindController() {
        canCheckForUpdates = controller.canCheckForUpdates

        controller.canCheckForUpdatesPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        settings.$checkForUpdatesAutomatically
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldAutomaticallyCheck in
                self?.controller.automaticallyChecksForUpdates = shouldAutomaticallyCheck
            }
            .store(in: &cancellables)

        controller.automaticallyChecksForUpdates = settings.checkForUpdatesAutomatically
    }

    func checkForUpdates() {
        state = .checking
        controller.checkForUpdates()
    }

    func recordUpdateFound(version: String?) {
        state = .updateAvailable(version: version)
    }

    func recordNoUpdate(_ error: Error) {
        state = Self.classifyNoUpdate(error)
    }

    func recordUpdateDismissed() {
        state = .idle
    }

    func recordUpdateFailure(_ error: Error) {
        state = Self.classifyFailure(error)
    }

    func finishUpdateCycle(error: Error?) {
        guard let error else {
            guard case .checking = state else { return }
            state = .idle
            return
        }

        let noUpdateState = Self.classifyNoUpdate(error)
        if case .upToDate = noUpdateState {
            state = noUpdateState
        } else {
            state = Self.classifyFailure(error)
        }
    }

    static func classifyNoUpdate(_ error: Error) -> UpdateState {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              nsError.code == 1001 else {
            return classifyFailure(error)
        }

        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        switch reason {
        case SparkleNoUpdateReason.onLatestVersion.rawValue,
             SparkleNoUpdateReason.onNewerThanLatestVersion.rawValue,
             SparkleNoUpdateReason.unknown.rawValue,
             nil:
            return .upToDate
        case SparkleNoUpdateReason.systemIsTooOld.rawValue:
            return .failed(errorSummary: "Update requires a newer version of macOS.")
        case SparkleNoUpdateReason.systemIsTooNew.rawValue:
            return .failed(errorSummary: "Update metadata does not support this macOS version.")
        default:
            return .upToDate
        }
    }

    static func classifyFailure(_ error: Error) -> UpdateState {
        let message = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return .failed(errorSummary: "Update check failed.")
        }
        return .failed(errorSummary: message)
    }
}

// MARK: - Delegate Handler

private final class UpdateDelegateHandler: NSObject, SPUUpdaterDelegate {
    let onUpdateFound: @MainActor (String?) -> Void
    let onNoUpdateFound: @MainActor (Error) -> Void
    let onUpdateDismissed: @MainActor () -> Void
    let onUpdateFailed: @MainActor (Error) -> Void
    let onUpdateCycleFinished: @MainActor (Error?) -> Void

    init(
        onUpdateFound: @escaping @MainActor (String?) -> Void,
        onNoUpdateFound: @escaping @MainActor (Error) -> Void,
        onUpdateDismissed: @escaping @MainActor () -> Void,
        onUpdateFailed: @escaping @MainActor (Error) -> Void,
        onUpdateCycleFinished: @escaping @MainActor (Error?) -> Void
    ) {
        self.onUpdateFound = onUpdateFound
        self.onNoUpdateFound = onNoUpdateFound
        self.onUpdateDismissed = onUpdateDismissed
        self.onUpdateFailed = onUpdateFailed
        self.onUpdateCycleFinished = onUpdateCycleFinished
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
            self.onNoUpdateFound(error)
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
        Task { @MainActor in
            self.onUpdateFailed(error)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        Task { @MainActor in
            self.onUpdateCycleFinished(error)
        }
    }
}
