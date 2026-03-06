import Combine
@preconcurrency import Sparkle

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case updateAvailable(version: String?)
    case upToDate
    case failed(errorSummary: String)
}

enum SparkleNoUpdateReason: Int {
    case unknown = 0
    case onLatestVersion = 1
    case onNewerThanLatestVersion = 2
    case systemIsTooOld = 3
    case systemIsTooNew = 4
}

struct UpdateErrorSnapshot: Sendable {
    let domain: String
    let code: Int
    let localizedDescription: String
    let noUpdateReason: Int?

    init(error: Error) {
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
        self.localizedDescription = nsError.localizedDescription
        self.noUpdateReason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
    }
}

enum UpdateStateClassifier {
    static func classifyNoUpdate(_ snapshot: UpdateErrorSnapshot) -> UpdateState {
        guard snapshot.domain == SUSparkleErrorDomain,
              snapshot.code == 1001 else {
            return classifyFailure(snapshot)
        }

        switch snapshot.noUpdateReason {
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

    static func classifyFailure(_ snapshot: UpdateErrorSnapshot) -> UpdateState {
        let message = snapshot.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return .failed(errorSummary: "Update check failed.")
        }
        return .failed(errorSummary: message)
    }

    static func classifyCycleResult(_ snapshot: UpdateErrorSnapshot?) -> UpdateState? {
        guard let snapshot else { return nil }
        let noUpdateState = classifyNoUpdate(snapshot)
        if case .upToDate = noUpdateState {
            return noUpdateState
        }
        return classifyFailure(snapshot)
    }
}

@MainActor
protocol UpdateControlling: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }

    func checkForUpdates()
}

@MainActor
final class UpdateManager: ObservableObject {
    private let settings: AppSettings
    private var controller: (any UpdateControlling)!
    private var delegateHandler: UpdateDelegateHandler?
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

    init(
        settings: AppSettings,
        controller: any UpdateControlling,
        delegateHandler: UpdateDelegateHandler? = nil
    ) {
        self.settings = settings
        self.controller = controller
        self.delegateHandler = delegateHandler
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
        recordNoUpdate(Self.classifyNoUpdate(error))
    }

    func recordNoUpdate(_ state: UpdateState) {
        self.state = state
    }

    func recordUpdateDismissed() {
        state = .idle
    }

    func recordUpdateFailure(_ error: Error) {
        recordUpdateFailure(Self.classifyFailure(error))
    }

    func recordUpdateFailure(_ state: UpdateState) {
        self.state = state
    }

    func finishUpdateCycle(error: Error?) {
        finishUpdateCycle(
            state: error.map { UpdateStateClassifier.classifyCycleResult(UpdateErrorSnapshot(error: $0)) } ?? nil
        )
    }

    func finishUpdateCycle(state: UpdateState?) {
        guard let state else {
            guard case .checking = self.state else { return }
            self.state = .idle
            return
        }
        self.state = state
    }

    static func classifyNoUpdate(_ error: Error) -> UpdateState {
        UpdateStateClassifier.classifyNoUpdate(UpdateErrorSnapshot(error: error))
    }

    static func classifyFailure(_ error: Error) -> UpdateState {
        UpdateStateClassifier.classifyFailure(UpdateErrorSnapshot(error: error))
    }
}
