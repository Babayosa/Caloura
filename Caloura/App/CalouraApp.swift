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

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending debounced saves before the app exits.
        AppState.shared.saveHistoryNow()
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.moveToApplicationsFolderIfNeeded() { return }

        cleanupStaleTempFiles()

        let launchStart = CFAbsoluteTimeGetCurrent()
        HotKeyManager.shared.registerAll()
        setupNotificationHandlers()

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

        if !AppSettings.shared.hasCompletedOnboarding {
            // First launch — always show setup guide
            onboardingController.showIfNeeded(settings: AppSettings.shared)
        } else if passiveStatus == .denied {
            // Returning user with denied permission can be guided via onboarding.
            onboardingController.show(settings: AppSettings.shared)
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

    private func setupNotificationHandlers() {
        setupCaptureHandlers()
        setupPostCaptureHandlers()
        setupAIHandlers()
        setupUIHandlers()
    }

    private func setupCaptureHandlers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: .captureArea, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.captureArea()
            }
        }

        nc.addObserver(forName: .captureWindow, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.captureWindow()
            }
        }

        nc.addObserver(forName: .captureFullscreen, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.captureFullscreen()
            }
        }

        nc.addObserver(forName: .captureRepeat, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.captureRepeat()
            }
        }

        nc.addObserver(forName: .captureDelayedArea, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.captureDelayed(seconds: 3, mode: .area)
            }
        }

        nc.addObserver(forName: .captureDelayedFullscreen, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.captureDelayed(seconds: 3, mode: .fullscreen)
            }
        }

        nc.addObserver(forName: .cancelDelayedCapture, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.cancelDelayedCapture()
            }
        }
    }

    private func setupPostCaptureHandlers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: .copyLastAsMarkdown, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.copyLastAsMarkdown()
            }
        }

        nc.addObserver(forName: .copyLastWithCitation, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.copyLastWithCitation()
            }
        }

        nc.addObserver(forName: .copyLastOCRText, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CapturePipeline.shared.copyLastOCRText()
            }
        }

        nc.addObserver(forName: .annotateLastCapture, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard let screenshot = AppState.shared.lastScreenshot else { return }
                self.annotationController.show(image: screenshot.image) { annotatedImage in
                    if let cgImage = annotatedImage.cgImage(
                        forProposedRect: nil, context: nil, hints: nil
                    ) {
                        if let filePath = screenshot.filePath {
                            do {
                                let pngData = try ImageProcessor.pngRepresentation(of: cgImage)
                                try pngData.write(to: filePath)
                            } catch {
                                Logger(
                                    subsystem: "com.caloura.app",
                                    category: "Annotation"
                                ).error(
                                    "Failed to save annotated image: \(error.localizedDescription)"
                                )
                            }
                        }
                    }
                }
            }
        }

        nc.addObserver(forName: .pinScreenshot, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard let screenshot = AppState.shared.lastScreenshot else { return }
                PinnedScreenshotManager.shared.pin(screenshot)
            }
        }

    }

    private func setupAIHandlers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: .beautifyLastCapture, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard let screenshot = AppState.shared.lastScreenshot else { return }
                BeautifyPreviewController.shared.show(
                    cgImage: screenshot.cgImage,
                    filePath: screenshot.filePath
                )
            }
        }

        nc.addObserver(forName: .redactLastCapture, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard let screenshot = AppState.shared.lastScreenshot else { return }
                let pii = AppState.shared.lastPIIResult
                if let pii, !pii.detections.isEmpty {
                    RedactionReviewController.shared.show(
                        cgImage: screenshot.cgImage,
                        detections: pii.detections,
                        filePath: screenshot.filePath
                    )
                } else {
                    do {
                        let detections = try await PIIDetector.detect(
                            in: screenshot.cgImage
                        )
                        if detections.isEmpty {
                            AppState.shared.statusMessage = "No PII detected"
                        } else {
                            RedactionReviewController.shared.show(
                                cgImage: screenshot.cgImage,
                                detections: detections,
                                filePath: screenshot.filePath
                            )
                        }
                    } catch {
                        AppState.shared.statusMessage = "PII detection failed"
                    }
                }
            }
        }
    }

    private func setupUIHandlers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: .showHistory, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.historyController.show(appState: AppState.shared)
            }
        }

        nc.addObserver(forName: .showSettings, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PreferencesWindowController.shared.show()
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
