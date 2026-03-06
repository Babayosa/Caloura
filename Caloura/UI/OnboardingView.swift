import SwiftUI
import os.log

let onboardingLogger = Logger(subsystem: "com.caloura.app", category: "Onboarding")

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissionCoordinator = PermissionCoordinator.shared
    @State var flow = OnboardingFlowModel()
    @State var hasAutoSkippedPermissionStep = false
    @State var isCheckingPermission = false
    @State var isAwaitingAutoCheckAfterGrant = false
    @State var iconAppeared = false
    var onComplete: () -> Void

    var permissionPresentation: OnboardingPermissionPresentation {
        OnboardingPermissionPresentation.from(permissionCoordinator.permissionUIModel)
    }

    /// Transition that moves in correct direction based on navigation
    private var stepTransition: AnyTransition {
        let isForward = flow.currentStep.rawValue > flow.previousStep.rawValue
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack {
            // Warm background gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.orange.opacity(0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                dotStepper
                    .padding(.top, 28)

                Spacer()

                Group {
                    switch flow.currentStep {
                    case .permission:
                        permissionStep
                    case .firstCapture:
                        firstCaptureStep
                    }
                }
                .id(flow.currentStep)
                .transition(stepTransition)

                Spacer()

                navigationFooter
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 540, height: 460)
        .onAppear {
            refreshPermissionStatus()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                iconAppeared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onChange(of: permissionCoordinator.permissionUIModel.status) { _, status in
            handlePermissionStatus(status)
        }
    }

    // MARK: - Dot Stepper

    private var dotStepper: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                VStack(spacing: 6) {
                    Circle()
                        .fill(step.rawValue <= flow.currentStep.rawValue
                              ? Color.accentColor
                              : Color.gray.opacity(0.25))
                        .frame(width: 8, height: 8)
                        .scaleEffect(step == flow.currentStep ? 1.3 : 1.0)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.6),
                            value: flow.currentStep
                        )

                    if step == flow.currentStep {
                        Text(step == .permission ? "Setup" : "Ready")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
            }
        }
    }

    // MARK: - Navigation Footer

    private var navigationFooter: some View {
        HStack {
            if !flow.isFirstStep {
                Button {
                    navigateBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if flow.isLastStep {
                Button {
                    finishOnboarding(startCapture: false)
                } label: {
                    Label("Finish", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    navigateNext()
                } label: {
                    Label("Continue", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(permissionPresentation.detail != .working)
            }
        }
    }

    // MARK: - Navigation

    func navigate(to step: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.3)) {
            if step.rawValue > flow.currentStep.rawValue {
                flow.next()
            } else {
                flow.back()
            }
        }
    }

    private func navigateNext() {
        guard !flow.isLastStep else { return }
        navigate(to: .firstCapture)
    }

    private func navigateBack() {
        guard !flow.isFirstStep else { return }
        navigate(to: .permission)
    }

    func finishOnboarding(startCapture: Bool) {
        settings.hasCompletedOnboarding = true
        settings.hasSeenWelcome = true
        onComplete()

        if startCapture {
            DispatchQueue.main.async {
                AppCommandRouter.shared.dispatch(.captureArea)
            }
        }
    }

    private func refreshPermissionStatus() {
        if isAwaitingAutoCheckAfterGrant {
            // User just granted — run full validation (with auto-repair)
            runUserInitiatedValidation()
        } else {
            let status = permissionCoordinator.refreshPassiveStatus()
            handlePermissionStatus(status)
        }
    }

    func runUserInitiatedValidation() {
        guard !isCheckingPermission else { return }
        isCheckingPermission = true
        Task { @MainActor in
            defer { isCheckingPermission = false }
            let status = await permissionCoordinator.runUserInitiatedValidation()
            handlePermissionStatus(status)
            isAwaitingAutoCheckAfterGrant = false
        }
    }

    private func handlePermissionStatus(_ status: PermissionStatus) {
        let desc = String(describing: status)
        onboardingLogger.info("Permission status changed: \(desc, privacy: .public)")
        if status == .grantedWorking && !hasAutoSkippedPermissionStep {
            hasAutoSkippedPermissionStep = true
            flow.skipPermissionIfReady(true)
        }
        if status == .grantedWorking {
            isAwaitingAutoCheckAfterGrant = false
        }
    }
}

// MARK: - Onboarding Window Controller

@MainActor
final class OnboardingWindowController {
    private let presenter = SingleWindowPresenter<OnboardingView>()

    func showIfNeeded(settings: AppSettings) {
        guard !settings.hasCompletedOnboarding else { return }
        show(settings: settings)
    }

    func show(settings: AppSettings) {
        let config = SingleWindowPresenter<OnboardingView>.WindowConfig(
            title: "Welcome to Caloura",
            size: CGSize(width: 540, height: 460)
        )
        presenter.show(config: config) {
            OnboardingView(settings: settings) { [weak self] in
                self?.presenter.close()
            }
        }
    }
}
