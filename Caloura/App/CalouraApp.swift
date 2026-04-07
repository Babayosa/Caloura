import os.log
import ServiceManagement
import SwiftUI
import KeyboardShortcuts

private let appLaunchLogger = Logger(subsystem: "com.caloura.app", category: "Launch")

@main
struct CalouraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: AppState.shared, settings: AppSettings.shared)
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let onboardingController = OnboardingWindowController()
    private let historyController = HistoryWindowController()
    private let annotationController = AnnotationWindowController()
    private let nagController = NagWindowController()
    private lazy var commandController = AppCommandController(
        onboardingController: onboardingController,
        historyController: historyController,
        annotationController: annotationController
    )
    private var isInitialLaunch = true
    private var commandHandlerID: UUID?
    private var captureObserver: NSObjectProtocol?

    private var isUITestHostEnabled: Bool {
        #if DEBUG
        UITestLaunchContext.isEnabled
        #else
        false
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
        }
        // Synchronous flush — blocks until written, ensuring data survives process exit.
        AppState.shared.saveHistorySync()
        AppSettings.shared.saveAllSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if isUITestHostEnabled { return }

        // Skip the first activation — applicationDidFinishLaunching already checks.
        if isInitialLaunch {
            isInitialLaunch = false
            return
        }
        guard AppMover.currentInstallState == .inApplications else { return }
        Task { @MainActor in
            ScreenCaptureManager.shared.resetSCKState()
            let status = await PermissionCoordinator.shared.refreshPassiveStatus()
            AppState.shared.hasScreenRecordingPermission = status != .denied
            if status != .denied {
                await ScreenCaptureManager.shared.prewarmWindowShareableContent()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isUITestHostEnabled {
            cleanupStaleTempFiles()
            NSApp.setActivationPolicy(.regular)
            setupCommandHandlers()
            #if DEBUG
            UITestHostWindowController.shared.show()
            #endif
            return
        }

        cleanupStaleTempFiles()

        if AppMover.currentInstallState != .inApplications {
            onboardingController.show(
                settings: AppSettings.shared,
                initialState: .installRequired
            )
            return
        }

        let launchStart = CFAbsoluteTimeGetCurrent()
        HotKeyManager.shared.registerAll()
        setupCommandHandlers()
        registerCaptureObserver()

        // Register URL scheme handler
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        do {
            try FileOrganizer.ensureBaseDirectory(AppSettings.shared.saveDirectory)
        } catch {
            let message = "Save directory unavailable: \(error.localizedDescription)"
            appLaunchLogger.error("\(message, privacy: .public)")
            AppState.shared.statusMessage = message
        }

        // Sync launch-at-login state with system
        syncLaunchAtLoginState()
        let setupElapsed = (CFAbsoluteTimeGetCurrent() - launchStart) * 1000
        appLaunchLogger.debug(
            "Synchronous launch setup completed in \(setupElapsed, privacy: .public) ms"
        )

        // Check passive screen recording status (non-interactive) and handle onboarding.
        let permissionCheckStart = CFAbsoluteTimeGetCurrent()
        Task { @MainActor [onboardingController, nagController] in
            let permissionCoordinator = PermissionCoordinator.shared
            let pendingCaptureMode = permissionCoordinator.takePendingCaptureResumeIfFresh()
            let shouldResumePendingCapture = pendingCaptureMode != nil
            var launchPermissionStatus = await permissionCoordinator.refreshPassiveStatus()
            AppState.shared.hasScreenRecordingPermission = launchPermissionStatus != .denied
            if launchPermissionStatus != .denied {
                await ScreenCaptureManager.shared.prewarmWindowShareableContent()
            }

            if shouldResumePendingCapture, launchPermissionStatus == .grantedNeedsValidation {
                launchPermissionStatus = await permissionCoordinator.runUserInitiatedValidation()
                AppState.shared.hasScreenRecordingPermission = launchPermissionStatus != .denied
            }

            if shouldResumePendingCapture, launchPermissionStatus == .working {
                AppSettings.shared.hasSeenWelcome = true
                Self.dispatchPendingCapture(mode: pendingCaptureMode ?? .area)

                let permissionDuration = (CFAbsoluteTimeGetCurrent() - permissionCheckStart) * 1000
                let totalLaunchDuration = (CFAbsoluteTimeGetCurrent() - launchStart) * 1000
                appLaunchLogger.debug(
                    "Passive permission diagnostics completed in \(permissionDuration, privacy: .public) ms"
                )
                appLaunchLogger.info("Launch flow ready in \(totalLaunchDuration, privacy: .public) ms")
                return
            }

            var showedOnboarding = false
            if shouldResumePendingCapture {
                onboardingController.show(
                    settings: AppSettings.shared,
                    initialState: onboardingFlowState(
                        for: launchPermissionStatus,
                        hasCompletedOnboarding: AppSettings.shared.hasCompletedOnboarding
                    )
                )
                showedOnboarding = true
            } else if !AppSettings.shared.hasCompletedOnboarding {
                onboardingController.showIfNeeded(settings: AppSettings.shared)
                showedOnboarding = true
            } else if launchPermissionStatus == .denied {
                onboardingController.show(
                    settings: AppSettings.shared,
                    initialState: .grantScreenRecording
                )
                showedOnboarding = true
            }

            // Show nag once per launch if trial expired and unlicensed,
            // but not if we're already showing onboarding/permission repair.
            if !showedOnboarding && AppSettings.shared.hasCompletedOnboarding {
                nagController.showIfNeeded()
            }

            let permissionDuration = (CFAbsoluteTimeGetCurrent() - permissionCheckStart) * 1000
            let totalLaunchDuration = (CFAbsoluteTimeGetCurrent() - launchStart) * 1000
            appLaunchLogger.debug(
                "Passive permission diagnostics completed in \(permissionDuration, privacy: .public) ms"
            )
            appLaunchLogger.info("Launch flow ready in \(totalLaunchDuration, privacy: .public) ms")
        }
    }

    private func registerCaptureObserver() {
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
        }
        captureObserver = NotificationCenter.default.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !AppSettings.shared.hasCompletedOnboarding else { return }
                AppSettings.shared.hasCompletedOnboarding = true
                AppSettings.shared.hasSeenWelcome = true
                onboardingLogger.info("funnel_event=first_capture_completed")
                self?.onboardingController.close()
            }
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        // Apple Event selectors may be invoked off the main thread via the ObjC runtime,
        // bypassing @MainActor isolation. Dispatch explicitly to guarantee main thread.
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        Task { @MainActor in
            URLSchemeHandler.handle(url)
        }
    }

    private func setupCommandHandlers() {
        commandHandlerID = AppCommandRouter.shared.addHandler { [weak self] command in
            self?.commandController.handle(command)
        }
    }

    private func cleanupStaleTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("caloura-")
            && url.pathExtension == "png" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func syncLaunchAtLoginState() {
        let settings = AppSettings.shared
        let status = SMAppService.mainApp.status
        if status == .enabled && !settings.launchAtLogin {
            settings.launchAtLogin = true
        } else if status == .requiresApproval {
            // User hasn't decided yet — don't flip the setting
        } else if status != .enabled && settings.launchAtLogin {
            settings.launchAtLogin = false
        }
        if settings.launchAtLogin && status != .enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                let desc = error.localizedDescription
                appLaunchLogger.warning("SMAppService.register() failed: \(desc, privacy: .public)")
                settings.launchAtLogin = false
            }
        }
    }

    private static func dispatchPendingCapture(mode: CaptureMode) {
        switch mode {
        case .area:
            AppCommandRouter.shared.dispatch(.captureArea)
        case .window:
            AppCommandRouter.shared.dispatch(.captureWindow)
        case .fullscreen:
            AppCommandRouter.shared.dispatch(.captureFullscreen)
        }
    }
}
