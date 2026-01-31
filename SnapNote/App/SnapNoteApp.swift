import SwiftUI
import KeyboardShortcuts

@main
struct SnapNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var pipeline = CapturePipeline.shared
    @StateObject private var updateManager = UpdateManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, settings: settings)
        } label: {
            Image(systemName: "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let onboardingController = OnboardingWindowController()
    private let historyController = HistoryWindowController()
    private let annotationController = AnnotationWindowController()

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

        // Show onboarding on first launch
        if !AppSettings.shared.hasCompletedOnboarding {
            onboardingController.showIfNeeded(settings: AppSettings.shared)
        }

        // Ensure save directory exists
        try? FileOrganizer.ensureBaseDirectory(AppSettings.shared.saveDirectory)

        // Check screen recording permission (no prompt for CG, async verify for SCK)
        AppState.shared.hasScreenRecordingPermission = ScreenCaptureManager.shared.checkPermission()
        Task {
            let sckOK = await ScreenCaptureManager.shared.verifySCKAccess()
            AppState.shared.hasScreenRecordingPermission = sckOK
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        URLSchemeHandler.handle(url)
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
    }
}
