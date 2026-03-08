import Foundation

enum OnboardingFlowState: String, Equatable {
    case installRequired
    case readyForFirstCapture
    case grantScreenRecording
    case waitingForSettingsReturn
    case repairStalePermissionRecord
    case completed

    fileprivate var transitionIndex: Int {
        switch self {
        case .installRequired:
            return 0
        case .readyForFirstCapture:
            return 1
        case .grantScreenRecording, .waitingForSettingsReturn, .repairStalePermissionRecord:
            return 2
        case .completed:
            return 3
        }
    }
}

struct OnboardingFlowModel {
    private(set) var currentState: OnboardingFlowState
    private(set) var previousState: OnboardingFlowState

    init(initialState: OnboardingFlowState = .readyForFirstCapture) {
        self.currentState = initialState
        self.previousState = initialState
    }

    var isCompleted: Bool {
        currentState == .completed
    }

    var transitionIsForward: Bool {
        currentState.transitionIndex >= previousState.transitionIndex
    }

    mutating func transition(to state: OnboardingFlowState) {
        guard state != currentState else { return }
        previousState = currentState
        currentState = state
    }
}
