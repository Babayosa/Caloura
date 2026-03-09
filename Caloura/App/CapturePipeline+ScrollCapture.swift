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

        replaceOverlayWindows(CaptureOverlayWindow.showOnAllScreens(
            frozenImages: frozenImages,
            onRegionSelected: { [weak self] rect, screen in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.captureSessionID == sessionID else { return }
                    self.clearOverlayWindows()
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
                    self.clearOverlayWindows()
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
        ))
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
        let request = ScrollCaptureEngine.Request(
            region: rect,
            geometry: geometry,
            config: config,
            targetAppName: targetAppName
        )
        let task = Task {
            await engine.capture(
                request,
                control: sessionCoordinator.control,
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
            let logMessage = scrollCaptureFailureLogMessage(for: error)
            scrollCaptureLogger.error(
                "Scroll capture failed: \(logMessage, privacy: .public)"
            )
            appState.statusMessage = scrollCaptureFailureStatusMessage(for: error)
            appState.isCapturing = false
        }
    }

    private func scrollCaptureFailureStatusMessage(for error: Error) -> String {
        if let scrollError = error as? ScrollCaptureError {
            switch scrollError {
            case .noScrollableViewport:
                return "No scrollable area was found in that selection. "
                    + "Select only the scrolling content and try again."
            case .noScrollTarget:
                return "The selected area did not scroll. "
                    + "Select a scrolling area and try again."
            case .unstableScrolling:
                return "Scroll capture could not stabilize the page. "
                    + "Wait for motion to stop, or switch to manual mode."
            case .framePreparationFailed:
                return "Scroll capture could not prepare the captured frames. "
                    + "Try again after the content finishes loading."
            case .noFramesCaptured:
                return "Scroll capture did not capture any content. Try again."
            case .canvasCreationFailed:
                return "Scroll capture could not assemble the final image. "
                    + "Try a smaller region or lower the maximum scroll height."
            }
        }

        return captureFailureStatusMessage(for: error, operation: "Scroll capture")
    }

    private func scrollCaptureFailureLogMessage(for error: Error) -> String {
        if let scrollError = error as? ScrollCaptureError {
            switch scrollError {
            case .noScrollableViewport:
                return "No scrollable viewport found in selected region"
            case .noScrollTarget:
                return "Selected region did not scroll"
            case .unstableScrolling:
                return "Scroll stabilization failed"
            case .framePreparationFailed:
                return "Failed to prepare a captured scroll frame"
            case .noFramesCaptured:
                return "Scroll capture produced zero frames"
            case .canvasCreationFailed:
                return "Failed to stitch scroll capture frames"
            }
        }

        return captureFailureLogMessage(for: error, operation: "Scroll capture")
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
