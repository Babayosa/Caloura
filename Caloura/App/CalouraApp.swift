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
    private var isInitialLaunch = true
    private var commandHandlerID: UUID?
    private var captureObserver: NSObjectProtocol?

    func applicationWillTerminate(_ notification: Notification) {
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
        }
        // Synchronous flush — blocks until written, ensuring data survives process exit.
        AppState.shared.saveHistorySync()
        AppSettings.shared.saveAllSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if UITestLaunchContext.isEnabled { return }

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
        if UITestLaunchContext.isEnabled {
            cleanupStaleTempFiles()
            NSApp.setActivationPolicy(.regular)
            setupCommandHandlers()
            UITestHostWindowController.shared.show()
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
            let passiveStatus = await PermissionCoordinator.shared.refreshPassiveStatus()
            AppState.shared.hasScreenRecordingPermission = passiveStatus != .denied
            if passiveStatus != .denied {
                await ScreenCaptureManager.shared.prewarmWindowShareableContent()
            }

            var showedOnboarding = false
            if !AppSettings.shared.hasCompletedOnboarding {
                onboardingController.showIfNeeded(settings: AppSettings.shared)
                showedOnboarding = true
            } else if passiveStatus == .denied {
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
            self?.handle(command)
        }
    }

    private func handle(_ command: AppCommand) {
        switch command {
        case .captureArea:
            CapturePipeline.shared.captureArea()
        case .captureWindow:
            CapturePipeline.shared.captureWindow()
        case .captureFullscreen:
            CapturePipeline.shared.captureFullscreen()
        case .captureRepeat:
            CapturePipeline.shared.captureRepeat()
        case .captureDelayed(let mode, let seconds):
            CapturePipeline.shared.captureDelayed(seconds: seconds, mode: mode)
        case .cancelDelayedCapture:
            CapturePipeline.shared.cancelDelayedCapture()
        case .captureScroll:
            OnboardingTipsController.shared.showIfNeeded(.scroll)
            CapturePipeline.shared.captureScroll()
        case .copyLastImage:
            CapturePipeline.shared.copyLastImage()
        case .copyLastAsMarkdown:
            CapturePipeline.shared.copyLastAsMarkdown()
        case .copyLastWithCitation:
            CapturePipeline.shared.copyLastWithCitation()
        case .copyLastOCRText:
            CapturePipeline.shared.copyLastOCRText()
        case .saveLastCapture:
            CapturePipeline.shared.saveLastCapture()
        case .annotateLastCapture:
            handleAnnotateLastCapture()
        case .pinScreenshot:
            handlePinScreenshot()
        case .beautifyLastCapture:
            handleBeautifyLastCapture()
        case .redactLastCapture:
            handleRedactLastCapture()
        case .showHistory:
            OnboardingTipsController.shared.showIfNeeded(.history)
            historyController.show(appState: AppState.shared)
        case .showSettings:
            PreferencesWindowController.shared.show()
        case .showPermissionRepair:
            showPermissionRepairWindow()
        }
    }

    private func showPermissionRepairWindow() {
        if AppMover.currentInstallState != .inApplications {
            onboardingController.show(
                settings: AppSettings.shared,
                initialState: .installRequired
            )
            return
        }

        Task { @MainActor in
            let currentStatus = PermissionCoordinator.shared.permissionUIModel.status
            let status: ScreenRecordingState
            switch currentStatus {
            case .needsRelaunch, .staleRecord, .repairing:
                status = currentStatus
            case .denied, .grantedNeedsValidation, .working:
                status = await PermissionCoordinator.shared.refreshPassiveStatus()
            }
            let state: OnboardingFlowState
            switch status {
            case .denied:
                state = .grantScreenRecording
            case .needsRelaunch, .staleRecord, .repairing:
                state = .repairStalePermissionRecord
            case .grantedNeedsValidation, .working:
                state = .completed
            }
            onboardingController.show(settings: AppSettings.shared, initialState: state)
        }
    }

    private func handleAnnotateLastCapture() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
        OnboardingTipsController.shared.showIfNeeded(.edit)
        annotationController.show(image: screenshot.image) { annotatedImage in
            if let cgImage = annotatedImage.cgImage(
                forProposedRect: nil, context: nil, hints: nil
            ) {
                Task { @MainActor in
                    do {
                        _ = try await ScreenshotArtifactCoordinator.shared.saveDerivedCapture(
                            cgImage,
                            basedOn: screenshot,
                            suggestedSuffix: "annotated"
                        )
                        AppState.shared.statusMessage = "Annotated image saved"
                    } catch is CancellationError {
                        AppState.shared.statusMessage = "Annotation save cancelled"
                    } catch {
                        Logger(
                            subsystem: "com.caloura.app",
                            category: "Annotation"
                        ).error(
                            "Failed to save annotated image: \(error.localizedDescription)"
                        )
                        AppState.shared.statusMessage = "Overwrite failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func handlePinScreenshot() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
        PinnedScreenshotManager.shared.pin(screenshot)
    }

    private func handleBeautifyLastCapture() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
        OnboardingTipsController.shared.showIfNeeded(.edit)
        BeautifyPreviewController.shared.show(screenshot: screenshot)
    }

    private func handleRedactLastCapture() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
        OnboardingTipsController.shared.showIfNeeded(.edit)
        let pii = AppState.shared.piiResult(for: screenshot.id)
        if let pii, !pii.detections.isEmpty {
            RedactionReviewController.shared.show(
                screenshot: screenshot,
                detections: pii.detections
            )
            return
        }

        Task {
            do {
                let detections = try await PIIDetector.detect(
                    in: screenshot.cgImage
                )
                if detections.isEmpty {
                    AppState.shared.statusMessage = "No PII detected"
                } else {
                    RedactionReviewController.shared.show(
                        screenshot: screenshot,
                        detections: detections
                    )
                }
            } catch {
                AppState.shared.statusMessage = "PII detection failed"
            }
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
}
