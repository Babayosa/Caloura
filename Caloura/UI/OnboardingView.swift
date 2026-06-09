import SwiftUI
import os.log

let onboardingLogger = Logger(subsystem: "com.caloura.app", category: "Onboarding")

struct OnboardingView: View {
    var settings: AppSettings
    var permissionCoordinator = PermissionCoordinator.shared
    @State var flow: OnboardingFlowModel
    @State var installState: AppInstallState
    @State var isCheckingPermission = false
    @State var iconAppeared = false
    @State var shouldResumePendingCapture = false
    @State var isAutoValidatingAfterSettings = false
    @State private var autoValidatePollTask: Task<Void, Never>?

    private let initialState: OnboardingFlowState
    private let onDismiss: () -> Void
    private let onStartFirstCapture: () -> Void

    init(
        settings: AppSettings,
        initialState: OnboardingFlowState,
        onDismiss: @escaping () -> Void,
        onStartFirstCapture: @escaping () -> Void
    ) {
        self.settings = settings
        self.initialState = initialState
        self.onDismiss = onDismiss
        self.onStartFirstCapture = onStartFirstCapture
        _flow = State(initialValue: OnboardingFlowModel(initialState: initialState))
        _installState = State(initialValue: AppMover.currentInstallState)
    }

    var permissionPresentation: OnboardingPermissionPresentation {
        OnboardingPermissionPresentation.from(permissionCoordinator.permissionUIModel)
    }

    private var stepTransition: AnyTransition {
        let isForward = flow.transitionIsForward
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.orange.opacity(0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topLabel
                    .padding(.top, 24)

                Spacer()

                Group {
                    switch flow.currentState {
                    case .installRequired:
                        installStep
                    case .readyForFirstCapture:
                        readyForFirstCaptureStep
                    case .grantScreenRecording, .waitingForSettingsReturn, .repairStalePermissionRecord:
                        permissionStep
                    case .completed:
                        completionStep
                    }
                }
                .id(flow.currentState)
                .transition(stepTransition)

                Spacer()
            }
            .padding(.bottom, 28)
        }
        .frame(width: 560, height: 480)
        .onAppear {
            onboardingLogger.info(
                "funnel_event=onboarding_opened state=\(initialState.rawValue, privacy: .public)"
            )
            syncInstallState()
            syncPermissionStateOnAppear()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                iconAppeared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            handleDidBecomeActive()
        }
        .task(id: flow.currentState) {
            guard flow.currentState == .completed, settings.hasCompletedOnboarding else {
                return
            }
            try? await Task.sleep(for: .milliseconds(800))
            guard flow.currentState == .completed, settings.hasCompletedOnboarding else {
                return
            }
            dismissWindow()
        }
    }

    private var topLabel: some View {
        Text(labelText(for: flow.currentState))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(1.4)
            .textCase(.uppercase)
    }

    private func labelText(for state: OnboardingFlowState) -> String {
        switch state {
        case .installRequired:
            return "Install"
        case .readyForFirstCapture:
            return "First Capture"
        case .grantScreenRecording, .waitingForSettingsReturn, .repairStalePermissionRecord:
            return "Permissions"
        case .completed:
            return "Ready"
        }
    }

    private func syncInstallState() {
        installState = AppMover.currentInstallState
        if installState == .inApplications && flow.currentState == .installRequired {
            transition(to: .readyForFirstCapture)
        }
    }

    private func syncPermissionStateOnAppear() {
        guard flow.currentState != .installRequired else { return }
        if flow.currentState == .readyForFirstCapture {
            Task { @MainActor in
                _ = await permissionCoordinator.primeIfPermissionGranted()
            }
            return
        }
        Task { @MainActor in
            let status = await permissionCoordinator.refreshPassiveStatus()
            handlePermissionStatus(status)
        }
    }

    private func handleDidBecomeActive() {
        syncInstallState()
        guard flow.currentState != .installRequired else { return }

        if flow.currentState == .waitingForSettingsReturn {
            revalidateAfterSettingsReturn()
            return
        }

        if flow.currentState == .grantScreenRecording || flow.currentState == .repairStalePermissionRecord {
            Task { @MainActor in
                let status = await permissionCoordinator.refreshPassiveStatus()
                handlePermissionStatus(status)
            }
        }
    }

    private func transition(to state: OnboardingFlowState) {
        if state != .waitingForSettingsReturn {
            cancelSettingsReturnPolling()
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            flow.transition(to: state)
        }
    }

    private func startSettingsReturnPolling() {
        guard autoValidatePollTask == nil else { return }
        isAutoValidatingAfterSettings = true
        onboardingLogger.info("funnel_event=settings_return_auto_poll_started")
        autoValidatePollTask = Task { @MainActor in
            defer {
                isAutoValidatingAfterSettings = false
                autoValidatePollTask = nil
            }
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                guard flow.currentState == .waitingForSettingsReturn else { return }
                let status = await permissionCoordinator.revalidateAfterSettingsReturn()
                syncPendingCaptureResume(for: status)
                if status != .grantedNeedsValidation {
                    handlePermissionStatus(status, launchCaptureOnSuccess: shouldResumePendingCapture)
                    return
                }
            }
        }
    }

    private func cancelSettingsReturnPolling() {
        autoValidatePollTask?.cancel()
        autoValidatePollTask = nil
        isAutoValidatingAfterSettings = false
    }

    func moveToApplications() {
        onboardingLogger.info("funnel_event=move_to_applications_requested")
        installState = .moving
        let result = AppMover.moveToApplicationsFolder()
        installState = result
        if case .moveFailed = result {
            onboardingLogger.error("funnel_event=move_to_applications_failed")
        }
    }

    func startFirstCapture() {
        onboardingLogger.info("funnel_event=first_capture_requested")
        shouldResumePendingCapture = true
        permissionCoordinator.armPendingCaptureResume(mode: .area)
        Task { @MainActor in
            let passiveStatus = await permissionCoordinator.refreshPassiveStatus()
            syncPendingCaptureResume(for: passiveStatus)
            switch passiveStatus {
            case .denied:
                requestScreenRecording()
            case .grantedNeedsValidation:
                runUserInitiatedValidation(launchCaptureOnSuccess: true)
            case .working:
                launchFirstCapture()
            case .needsRelaunch, .staleRecord, .repairing, .configurationFailed:
                handlePermissionStatus(passiveStatus)
            }
        }
    }

    func requestScreenRecording() {
        guard !isCheckingPermission else { return }
        onboardingLogger.info("funnel_event=screen_recording_prompt_requested")
        if shouldResumePendingCapture {
            permissionCoordinator.armPendingCaptureResume(mode: .area)
        }
        _ = permissionCoordinator.requestPermissionFromSystem()
        transition(to: .waitingForSettingsReturn)
    }

    func runUserInitiatedValidation(launchCaptureOnSuccess: Bool) {
        guard !isCheckingPermission else { return }
        isCheckingPermission = true
        Task { @MainActor in
            defer { isCheckingPermission = false }
            let status = await permissionCoordinator.runUserInitiatedValidation()
            syncPendingCaptureResume(for: status)
            handlePermissionStatus(status, launchCaptureOnSuccess: launchCaptureOnSuccess)
        }
    }

    func revalidateAfterSettingsReturn() {
        guard !isCheckingPermission else { return }
        isCheckingPermission = true
        onboardingLogger.info("funnel_event=screen_recording_settings_returned")
        Task { @MainActor in
            defer { isCheckingPermission = false }
            let status = await permissionCoordinator.revalidateAfterSettingsReturn()
            syncPendingCaptureResume(for: status)
            handlePermissionStatus(status, launchCaptureOnSuccess: shouldResumePendingCapture)
        }
    }

    private func syncPendingCaptureResume(for status: ScreenRecordingState) {
        guard shouldResumePendingCapture, status != .working else { return }
        permissionCoordinator.clearPendingCaptureResumeIfNoRelaunchPending()
    }

    func handlePermissionStatus(
        _ status: ScreenRecordingState,
        launchCaptureOnSuccess: Bool = false
    ) {
        onboardingLogger.info(
            "permission_status state=\(String(describing: status), privacy: .public)"
        )

        switch status {
        case .working:
            onboardingLogger.info("funnel_event=screen_recording_working")
            if launchCaptureOnSuccess || shouldResumePendingCapture {
                launchFirstCapture()
            } else {
                transition(to: .completed)
            }
        case .denied:
            transition(to: .grantScreenRecording)
        case .grantedNeedsValidation:
            if flow.currentState == .waitingForSettingsReturn {
                startSettingsReturnPolling()
                return
            }
            if !settings.hasCompletedOnboarding {
                transition(to: .readyForFirstCapture)
            } else if flow.currentState != .repairStalePermissionRecord {
                transition(to: .repairStalePermissionRecord)
            }
        case .needsRelaunch, .staleRecord, .repairing, .configurationFailed:
            transition(to: .repairStalePermissionRecord)
        }
    }

    func launchInstalledCopy() {
        if AppMover.relaunchFromApplicationsIfAvailable() {
            onboardingLogger.info("funnel_event=relaunch_installed_copy_requested")
            return
        }
        installState = .moveFailed("No /Applications copy is available yet. Move Caloura there first.")
    }

    func launchFirstCapture() {
        shouldResumePendingCapture = false
        permissionCoordinator.clearPendingCaptureResume()
        settings.hasSeenWelcome = true
        transition(to: .completed)
        onDismiss()
        DispatchQueue.main.async {
            self.onStartFirstCapture()
        }
    }

    func dismissWindow() {
        cancelSettingsReturnPolling()
        shouldResumePendingCapture = false
        permissionCoordinator.clearPendingCaptureResume()
        settings.hasSeenWelcome = true
        onDismiss()
    }
}

// MARK: - Onboarding Window Controller

@MainActor
final class OnboardingWindowController {
    private let presenter = SingleWindowPresenter<OnboardingView>()

    var isVisible: Bool {
        presenter.isVisible
    }

    var windowTitle: String? {
        presenter.window?.title
    }

    func showIfNeeded(settings: AppSettings) {
        guard !settings.hasCompletedOnboarding else { return }
        show(settings: settings, initialState: .readyForFirstCapture)
    }

    func show(
        settings: AppSettings,
        initialState: OnboardingFlowState = .readyForFirstCapture,
        activateApp: Bool = false
    ) {
        let config = SingleWindowPresenter<OnboardingView>.WindowConfig(
            title: "Welcome to Caloura",
            size: CGSize(width: 560, height: 480)
        )
        presenter.show(config: config, activateApp: activateApp) {
            OnboardingView(
                settings: settings,
                initialState: initialState,
                onDismiss: { [weak self] in
                    self?.presenter.close()
                },
                onStartFirstCapture: {
                    AppCommandRouter.shared.dispatch(.captureArea)
                }
            )
        }
    }

    func close() {
        presenter.close()
    }
}

@MainActor
final class OnboardingTipsController {
    static let shared = OnboardingTipsController(settings: .shared)

    private let settings: AppSettings
    private let presenter = SingleWindowPresenter<ContextualTipView>()
    private var hasShownTipThisSession = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func showIfNeeded(_ tip: ContextualOnboardingTip) {
        guard settings.hasCompletedOnboarding else { return }
        guard !settings.hasSeenContextualTip(tip) else { return }
        guard !hasShownTipThisSession else { return }

        hasShownTipThisSession = true
        settings.markContextualTipSeen(tip)
        onboardingLogger.info("funnel_event=contextual_tip_shown tip=\(tip.rawValue, privacy: .public)")

        let content = ContextualTipContent.content(for: tip)
        let config = SingleWindowPresenter<ContextualTipView>.WindowConfig(
            title: "Caloura Tip",
            size: CGSize(width: 360, height: 220)
        )
        presenter.show(config: config, activateApp: false) {
            ContextualTipView(
                content: content,
                onDismiss: { [weak self] in
                    self?.presenter.close()
                }
            )
        }
    }
}

private struct ContextualTipContent {
    let symbol: String
    let title: String
    let body: String

    static func content(for tip: ContextualOnboardingTip) -> ContextualTipContent {
        switch tip {
        case .history:
            return ContextualTipContent(
                symbol: "clock.arrow.circlepath",
                title: "History keeps recent captures searchable",
                body: "Open History to find, preview, and reuse the screenshots you just took without capturing them again."
            )
        case .edit:
            return ContextualTipContent(
                symbol: "pencil.tip.crop.circle",
                title: "Edit the capture you already have",
                body: "Annotate stays one click away, while Beautify and other "
                    + "follow-up actions live in the More menu after every shot."
            )
        case .share:
            return ContextualTipContent(
                symbol: "square.and.arrow.up.circle.fill",
                title: "Sharing is built into the first workflow",
                body: "Copy, save, Markdown, and citation actions are available immediately after capture from Quick Access and the menu."
            )
        }
    }
}

private struct ContextualTipView: View {
    let content: ContextualTipContent
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: content.symbol)
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text(content.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(content.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button("Got It", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(width: 360, height: 220)
    }
}
