import AppKit
import os.log
import ScreenCaptureKit

private let scrollEntryLogger = Logger(
    subsystem: "com.caloura.app",
    category: "CaptureEntry"
)
private let scrollCaptureLogger = Logger(
    subsystem: "com.caloura.app",
    category: "CapturePipeline"
)

extension CapturePipeline {

    // MARK: Scroll Capture

    func captureScroll() {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true
        captureSessionID &+= 1

        Task {
            let entryStart = CFAbsoluteTimeGetCurrent()
            scrollEntryLogger.debug("Scroll capture entry: request received")
            let frozenImages = await freezeScreens(entryStart: entryStart)
            showScrollAreaOverlays(
                frozenImages: frozenImages,
                entryStart: entryStart
            )
        }
    }

    private func showScrollAreaOverlays(
        frozenImages: [NSScreen: CGImage],
        entryStart: CFAbsoluteTime
    ) {
        firstMouseDownLogged = false
        let sessionID = captureSessionID

        overlayWindows = CaptureOverlayWindow.showOnAllScreens(
            frozenImages: frozenImages,
            onRegionSelected: { [weak self] rect, screen in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.captureSessionID == sessionID else { return }
                    self.overlayWindows = []
                    self.appState.lastCaptureRect = rect
                    self.appState.lastCaptureScreen = screen
                    await self.performScrollCapture(
                        rect: rect,
                        screen: screen
                    )
                }
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.captureSessionID == sessionID else { return }
                    self.overlayWindows = []
                    self.appState.isCapturing = false
                }
            },
            onFirstMouseDown: { [weak self] in
                guard let self = self, !self.firstMouseDownLogged else { return }
                self.firstMouseDownLogged = true
                let duration = self.elapsedMilliseconds(since: entryStart)
                scrollEntryLogger.info(
                    "Scroll capture entry: first mouseDown at \(duration, privacy: .public) ms"
                )
                self.recordMetric(
                    stage: .firstMouseDown,
                    milliseconds: duration
                )
            }
        )
    }

    func performScrollCapture(rect: CGRect, screen: NSScreen) async {
        // Brief delay to let overlay dismiss and frontmost app restore.
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard AccessibilityPermissionChecker.currentState() == .working else {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Scroll Capture needs Accessibility access to "
                + "simulate scrolling. Please grant access in System Settings."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                AccessibilityPermissionChecker.openSystemSettings()
            }
            appState.isCapturing = false
            return
        }

        let config = ScrollCaptureEngine.Config(
            maxHeightPx: settings.scrollMaxHeight,
            scrollToTop: settings.scrollToTop,
            allowManualFallback: true,
            preferredDirection: .auto,
            modeBias: .automaticPreferred
        )

        let sessionCoordinator = ScrollCaptureSessionCoordinator(
            rect: rect,
            screen: screen
        )

        let geometry = ScrollScreenGeometry(
            frame: screen.frame,
            scale: screen.backingScaleFactor,
            primaryScreenHeight: NSScreen.screens.first?.frame.height ?? screen.frame.height
        )
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        let captureFrameFn: @Sendable (CGRect) async throws -> CGImage = { rect in
            let displayRect = CGRect(
                x: geometry.frame.origin.x + rect.origin.x,
                y: geometry.primaryScreenHeight
                    - (geometry.frame.origin.y + rect.origin.y + rect.height),
                width: rect.width,
                height: rect.height
            ).integral
            return try await ScreenCaptureManager.shared.captureAreaInDisplaySpace(
                displayRect
            )
        }

        let engine = ScrollCaptureEngine()
        let task = Task {
            await engine.capture(
                region: rect,
                geometry: geometry,
                config: config,
                control: sessionCoordinator.control,
                targetAppName: targetAppName,
                captureFrame: captureFrameFn,
                onProgress: { progress in
                    sessionCoordinator.update(progress)
                }
            )
        }
        scrollCaptureTask = task
        sessionCoordinator.bind(task: task)

        let result = await task.value
        sessionCoordinator.dismiss()

        switch result {
        case .success(let output):
            if output.terminationReason == .manualFinished {
                appState.statusMessage = "Manual scroll capture finished"
            } else if output.terminationReason == .maxHeightReached {
                appState.statusMessage = "Scroll capture reached the max height"
            }
            await performCapture(mode: .scroll) { output.image }
        case .cancelled:
            appState.statusMessage = "Scroll capture cancelled"
            appState.isCapturing = false
        case .failed(CaptureError.noPermission):
            appState.isCapturing = false
            await PermissionCoordinator.shared.handleCapturePermissionFailure()
        case .failed(let error):
            let description = error.localizedDescription
            scrollCaptureLogger.error("Scroll capture failed: \(description, privacy: .public)")
            appState.statusMessage = "Scroll capture failed: \(description)"
            appState.isCapturing = false
        }
    }
}

@MainActor
private final class ScrollCaptureSessionCoordinator {
    let control = ScrollCaptureControl()

    private let overlay = ScrollProgressOverlay()
    private var task: Task<ScrollCaptureEngine.Result, Never>?

    init(rect: CGRect, screen: NSScreen) {
        overlay.show(
            near: rect,
            screen: screen,
            onCancel: { [weak self] in
                self?.task?.cancel()
            },
            onSwitchToManual: { [control] in
                Task {
                    await control.requestManual()
                }
            },
            onFinish: { [control] in
                Task {
                    await control.requestFinish()
                }
            }
        )
    }

    func bind(task: Task<ScrollCaptureEngine.Result, Never>) {
        self.task = task
    }

    func update(_ progress: ScrollCaptureProgress) {
        overlay.update(progress)
    }

    func dismiss() {
        overlay.dismiss()
        task = nil
    }
}
