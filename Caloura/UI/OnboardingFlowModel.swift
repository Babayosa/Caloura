import Foundation

enum OnboardingStep: Int, CaseIterable {
    case permission
    case firstCapture
}

struct OnboardingFlowModel {
    private(set) var currentStep: OnboardingStep = .permission
    private(set) var previousStep: OnboardingStep = .permission

    var isFirstStep: Bool { currentStep == .permission }
    var isLastStep: Bool { currentStep == .firstCapture }

    mutating func next() {
        guard let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        previousStep = currentStep
        currentStep = nextStep
    }

    mutating func back() {
        guard let previous = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        previousStep = currentStep
        currentStep = previous
    }

    mutating func skipPermissionIfReady(_ permissionReady: Bool) {
        guard permissionReady, currentStep == .permission else { return }
        previousStep = currentStep
        currentStep = .firstCapture
    }
}
