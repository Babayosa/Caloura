import ServiceManagement
import SwiftUI
import KeyboardShortcuts

@main
struct CalouraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: AppState.shared, settings: AppSettings.shared)
        } label: {
            Image(systemName: "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let onboardingController = OnboardingWindowController()
    private let historyController = HistoryWindowController()
    private let annotationController = AnnotationWindowController()
    private var isInitialLaunch = true

    func applicationDidBecomeActive(_ notification: Notification) {
        // Skip the first activation — applicationDidFinishLaunching already checks.
        if isInitialLaunch {
            isInitialLaunch = false
            return
        }
        Task {
            let sckOK = await ScreenCaptureManager.shared.checkSCKAccess()
            AppState.shared.hasScreenRecordingPermission = sckOK
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Check screen recording permission and handle onboarding
        AppState.shared.hasScreenRecordingPermission = ScreenCaptureManager.shared.checkPermission()
        Task {
            let sckOK = await ScreenCaptureManager.shared.checkSCKAccess()
            AppState.shared.hasScreenRecordingPermission = sckOK

            if !AppSettings.shared.hasCompletedOnboarding {
                // First launch — always show setup guide
                onboardingController.showIfNeeded(settings: AppSettings.shared)
            } else if !sckOK {
                // Returning user — SCK not working. Only auto-show the setup guide
                // if the OS says permission was never granted. If permission IS granted
                // but SCK is failing (e.g. debug build, signature issue), don't loop —
                // the user will see the diagnostic dialog on their next capture attempt.
                let state = ScreenCaptureManager.shared.diagnosePermissionState()
                if state == .neverGranted {
                    onboardingController.show(settings: AppSettings.shared)
                }
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

    private func setupNotificationHandlers() {
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
                    if let cgImage = annotatedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let pngData = ImageProcessor.pngRepresentation(of: cgImage)
                        if let filePath = screenshot.filePath {
                            try? pngData.write(to: filePath)
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

        nc.addObserver(forName: .showSetupGuide, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.onboardingController.show(settings: AppSettings.shared)
            }
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
            try? SMAppService.mainApp.register()
        }
    }
}
