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

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous flush — blocks until written, ensuring data survives process exit.
        AppState.shared.saveHistorySync()
        AppSettings.shared.saveAllSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Skip the first activation — applicationDidFinishLaunching already checks.
        if isInitialLaunch {
            isInitialLaunch = false
            return
        }
        let status = PermissionCoordinator.shared.refreshPassiveStatus()
        AppState.shared.hasScreenRecordingPermission = status != .denied
        if status != .denied {
            Task { @MainActor in
                await ScreenCaptureManager.shared.prewarmWindowShareableContent()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.moveToApplicationsFolderIfNeeded() { return }

        cleanupStaleTempFiles()

        let launchStart = CFAbsoluteTimeGetCurrent()
        HotKeyManager.shared.registerAll()
        setupCommandHandlers()

        // Register URL scheme handler
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Ensure save directory exists
        try? FileOrganizer.ensureBaseDirectory(AppSettings.shared.saveDirectory)

        // Sync launch-at-login state with system
        syncLaunchAtLoginState()
        let setupElapsed = (CFAbsoluteTimeGetCurrent() - launchStart) * 1000
        appLaunchLogger.debug(
            "Synchronous launch setup completed in \(setupElapsed, privacy: .public) ms"
        )

        // Check passive screen recording status (non-interactive) and handle onboarding.
        let permissionCheckStart = CFAbsoluteTimeGetCurrent()
        let passiveStatus = PermissionCoordinator.shared.refreshPassiveStatus()
        AppState.shared.hasScreenRecordingPermission = passiveStatus != .denied
        if passiveStatus != .denied {
            Task { @MainActor in
                await ScreenCaptureManager.shared.prewarmWindowShareableContent()
            }
        }

        if !AppSettings.shared.hasCompletedOnboarding {
            // First launch — always show setup guide
            onboardingController.showIfNeeded(settings: AppSettings.shared)
        } else if passiveStatus == .denied {
            // Returning user with denied permission can be guided via onboarding.
            onboardingController.show(settings: AppSettings.shared)
        } else if passiveStatus != .grantedWorking {
            // Returning user with broken permission — try silent auto-repair
            Task { @MainActor [onboardingController] in
                let status = await PermissionCoordinator.shared.runUserInitiatedValidation()
                if status != .grantedWorking {
                    onboardingController.show(settings: AppSettings.shared)
                }
            }
        }

        // Show nag once per launch if trial expired and unlicensed
        if AppSettings.shared.hasCompletedOnboarding {
            nagController.showIfNeeded()
        }

        let permissionDuration = (CFAbsoluteTimeGetCurrent() - permissionCheckStart) * 1000
        let totalLaunchDuration = (CFAbsoluteTimeGetCurrent() - launchStart) * 1000
        appLaunchLogger.debug("Passive permission diagnostics completed in \(permissionDuration, privacy: .public) ms")
        appLaunchLogger.info("Launch flow ready in \(totalLaunchDuration, privacy: .public) ms")
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
            CapturePipeline.shared.captureScroll()
        case .copyLastImage:
            CapturePipeline.shared.copyLastImage()
        case .copyLastAsMarkdown:
            CapturePipeline.shared.copyLastAsMarkdown()
        case .copyLastWithCitation:
            CapturePipeline.shared.copyLastWithCitation()
        case .copyLastOCRText:
            CapturePipeline.shared.copyLastOCRText()
        case .annotateLastCapture:
            handleAnnotateLastCapture()
        case .pinScreenshot:
            handlePinScreenshot()
        case .beautifyLastCapture:
            handleBeautifyLastCapture()
        case .redactLastCapture:
            handleRedactLastCapture()
        case .showHistory:
            historyController.show(appState: AppState.shared)
        case .showSettings:
            PreferencesWindowController.shared.show()
        case .showPermissionRepair:
            onboardingController.show(settings: AppSettings.shared)
        }
    }

    private func handleAnnotateLastCapture() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
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
        BeautifyPreviewController.shared.show(screenshot: screenshot)
    }

    private func handleRedactLastCapture() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
        let pii = AppState.shared.lastPIIResult
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
        } else if status != .enabled && settings.launchAtLogin {
            settings.launchAtLogin = false
        }
        if settings.launchAtLogin {
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
