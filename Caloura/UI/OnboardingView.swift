import SwiftUI
import os.log

private let onboardingLogger = Logger(subsystem: "com.caloura.app", category: "Onboarding")

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var permissionCoordinator = PermissionCoordinator.shared
    @State private var flow = OnboardingFlowModel()
    @State private var hasAutoSkippedPermissionStep = false
    @State private var isCheckingPermission = false
    @State private var isAwaitingAutoCheckAfterGrant = false
    var onComplete: () -> Void

    private var permissionPresentation: OnboardingPermissionPresentation {
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
        VStack(spacing: 0) {
            // Progress indicator - minimal line style
            HStack(spacing: 0) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Rectangle()
                        .fill(step.rawValue <= flow.currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.2))
                        .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
            .padding(.horizontal, 40)
            .padding(.top, 24)

            Spacer()

            // Step content with directional animation
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

            HStack {
                if !flow.isFirstStep {
                    Button("Back") {
                        navigateBack()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if flow.isLastStep {
                    Button("Finish") {
                        finishOnboarding(startCapture: false)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") {
                        navigateNext()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 500, height: 400)
        .onAppear {
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onChange(of: permissionCoordinator.permissionUIModel.status) { _, status in
            handlePermissionStatus(status)
        }
    }

    private func navigate(to step: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.25)) {
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

    private func finishOnboarding(startCapture: Bool) {
        settings.hasCompletedOnboarding = true
        settings.hasSeenWelcome = true
        onComplete()

        if startCapture {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .captureArea, object: nil)
            }
        }
    }

    private func refreshPermissionStatus() {
        let status = permissionCoordinator.refreshPassiveStatus()
        handlePermissionStatus(status)
    }

    private func runUserInitiatedValidation() {
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
        onboardingLogger.info("Permission status changed: \(String(describing: status), privacy: .public)")
        if status == .grantedWorking && !hasAutoSkippedPermissionStep {
            hasAutoSkippedPermissionStep = true
            flow.skipPermissionIfReady(true)
        }
        if status == .grantedWorking {
            isAwaitingAutoCheckAfterGrant = false
        }
    }

    // MARK: - Steps

    private var permissionStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Allow Screen Recording")
                .font(.title2)
                .fontWeight(.bold)

            Text("Caloura needs screen recording access to capture screenshots. "
                + "You can continue now and grant this later if needed.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            switch permissionPresentation.detail {
            case .working:
                Label(permissionPresentation.statusHeadline, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(permissionPresentation.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .grantedNotWorking:
                Label(permissionPresentation.statusHeadline, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(permissionPresentation.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Quit Caloura") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            case .notGranted:
                Label(permissionPresentation.statusHeadline, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(permissionPresentation.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .signatureMismatch:
                Label(permissionPresentation.statusHeadline, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(permissionPresentation.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                if permissionPresentation.shouldShowMismatchBanner {
                    Text("If you run both Xcode and public builds, macOS may authorize one build but deny the other.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .onAppear {
                            permissionCoordinator.markCurrentMismatchBannerShown()
                        }
                }
            }

            HStack(spacing: 10) {
                if permissionPresentation.showsGrantButton {
                    Button("Grant Permission") {
                        guard !isCheckingPermission, !isAwaitingAutoCheckAfterGrant else { return }
                        _ = permissionCoordinator.requestPermissionFromSystem()
                        isAwaitingAutoCheckAfterGrant = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            runUserInitiatedValidation()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCheckingPermission || isAwaitingAutoCheckAfterGrant)
                }

                if permissionPresentation.showsCheckAgainButton {
                    Button((isCheckingPermission || isAwaitingAutoCheckAfterGrant) ? "Checking..." : "Check Again") {
                        runUserInitiatedValidation()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCheckingPermission || isAwaitingAutoCheckAfterGrant)
                }
            }

            if isAwaitingAutoCheckAfterGrant {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Auto-checking permission...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var firstCaptureStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("You're Ready")
                .font(.title)
                .fontWeight(.bold)

            Text("Capture anytime with \u{2303}\u{21E7}4, or take your first screenshot now.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                shortcutRow(keys: "\u{2303}\u{21E7}4", action: "Capture Area")
                shortcutRow(keys: "\u{2303}\u{21E7}5", action: "Capture Window")
                shortcutRow(keys: "\u{2303}\u{21E7}3", action: "Capture Full Screen")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button("Take First Screenshot") {
                finishOnboarding(startCapture: true)
            }
            .buttonStyle(.bordered)
        }
    }

    private func shortcutRow(keys: String, action: String) -> some View {
        HStack {
            HStack(spacing: 3) {
                ForEach(Array(keys), id: \.self) { key in
                    Text(String(key))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 28, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            Text(action)
                .foregroundStyle(.secondary)
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
            size: CGSize(width: 500, height: 400)
        )
        presenter.show(config: config) {
            OnboardingView(settings: settings) { [weak self] in
                self?.presenter.close()
            }
        }
    }
}
