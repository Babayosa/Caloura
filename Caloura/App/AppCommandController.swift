import AppKit
import os.log

@MainActor
final class AppCommandController {
    struct Routing {
        let captureArea: @MainActor () -> Void
        let captureWindow: @MainActor () -> Void
        let captureFullscreen: @MainActor () -> Void
        let captureRepeat: @MainActor () -> Void
        let captureDelayed: @MainActor (CaptureMode, Int) -> Void
        let cancelDelayedCapture: @MainActor () -> Void
        let captureScroll: @MainActor () -> Void
        let copyLastImage: @MainActor () -> Void
        let copyLastAsMarkdown: @MainActor () -> Void
        let copyLastWithCitation: @MainActor () -> Void
        let copyLastOCRText: @MainActor () -> Void
        let saveLastCapture: @MainActor () -> Void
        let showTip: @MainActor (ContextualOnboardingTip) -> Void

        static let live = Routing(
            captureArea: { CapturePipeline.shared.captureArea() },
            captureWindow: { CapturePipeline.shared.captureWindow() },
            captureFullscreen: { CapturePipeline.shared.captureFullscreen() },
            captureRepeat: { CapturePipeline.shared.captureRepeat() },
            captureDelayed: { mode, seconds in
                CapturePipeline.shared.captureDelayed(seconds: seconds, mode: mode)
            },
            cancelDelayedCapture: { CapturePipeline.shared.cancelDelayedCapture() },
            captureScroll: { CapturePipeline.shared.captureScroll() },
            copyLastImage: { CapturePipeline.shared.copyLastImage() },
            copyLastAsMarkdown: { CapturePipeline.shared.copyLastAsMarkdown() },
            copyLastWithCitation: { CapturePipeline.shared.copyLastWithCitation() },
            copyLastOCRText: { CapturePipeline.shared.copyLastOCRText() },
            saveLastCapture: { CapturePipeline.shared.saveLastCapture() },
            showTip: { OnboardingTipsController.shared.showIfNeeded($0) }
        )
    }

    private let onboardingController: OnboardingWindowController
    private let historyController: HistoryWindowController
    private let annotationController: AnnotationWindowController
    private let routing: Routing
    private let annotationLogger = Logger(
        subsystem: "com.caloura.app",
        category: "Annotation"
    )

    init(
        onboardingController: OnboardingWindowController,
        historyController: HistoryWindowController,
        annotationController: AnnotationWindowController,
        routing: Routing = .live
    ) {
        self.onboardingController = onboardingController
        self.historyController = historyController
        self.annotationController = annotationController
        self.routing = routing
    }

    func handle(_ command: AppCommand) {
        if handleCaptureCommand(command) {
            return
        }
        if handleDistributionCommand(command) {
            return
        }

        handleWindowCommand(command)
    }

    private func handleCaptureCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .captureArea:
            routing.captureArea()
        case .captureWindow:
            routing.captureWindow()
        case .captureFullscreen:
            routing.captureFullscreen()
        case .captureRepeat:
            routing.captureRepeat()
        case .captureDelayed(let mode, let seconds):
            routing.captureDelayed(mode, seconds)
        case .cancelDelayedCapture:
            routing.cancelDelayedCapture()
        case .captureScroll:
            routing.showTip(.scroll)
            routing.captureScroll()
        default:
            return false
        }

        return true
    }

    private func handleDistributionCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .copyLastImage:
            routing.copyLastImage()
        case .copyLastAsMarkdown:
            routing.copyLastAsMarkdown()
        case .copyLastWithCitation:
            routing.copyLastWithCitation()
        case .copyLastOCRText:
            routing.copyLastOCRText()
        case .saveLastCapture:
            routing.saveLastCapture()
        case .annotateLastCapture:
            handleAnnotateLastCapture()
        case .pinScreenshot:
            handlePinScreenshot()
        case .beautifyLastCapture:
            handleBeautifyLastCapture()
        case .redactLastCapture:
            handleRedactLastCapture()
        default:
            return false
        }

        return true
    }

    private func handleWindowCommand(_ command: AppCommand) {
        switch command {
        case .showHistory:
            routing.showTip(.history)
            historyController.show(appState: AppState.shared)
        case .showSettings:
            PreferencesWindowController.shared.show()
        case .showPermissionRepair:
            showPermissionRepairWindow()
        default:
            break
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

            onboardingController.show(
                settings: AppSettings.shared,
                initialState: state
            )
        }
    }

    private func handleAnnotateLastCapture() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
        routing.showTip(.edit)
        annotationController.show(image: screenshot.image) { annotatedImage in
            guard let cgImage = annotatedImage.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ) else {
                return
            }

            Task { @MainActor in
                do {
                    _ = try await ScreenshotArtifactCoordinator.shared.saveDerivedCapture(
                        cgImage,
                        basedOn: screenshot,
                        suggestedSuffix: "annotated"
                    )
                    AppState.shared.setStatusMessage("Annotated image saved")
                } catch is CancellationError {
                    AppState.shared.setStatusMessage("Annotation save cancelled")
                } catch {
                    self.annotationLogger.error(
                        "Failed to save annotated image: \(error.localizedDescription)"
                    )
                    AppState.shared.setStatusMessage(
                        "Overwrite failed: \(error.localizedDescription)"
                    )
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
        routing.showTip(.edit)
        BeautifyPreviewController.shared.show(screenshot: screenshot)
    }

    private func handleRedactLastCapture() {
        guard let screenshot = AppState.shared.lastScreenshot else { return }
        routing.showTip(.edit)
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
                let detections = try await PIIDetector.detect(in: screenshot.cgImage)
                if detections.isEmpty {
                    AppState.shared.setStatusMessage("No PII detected")
                } else {
                    RedactionReviewController.shared.show(
                        screenshot: screenshot,
                        detections: detections
                    )
                }
            } catch {
                AppState.shared.setStatusMessage("PII detection failed")
            }
        }
    }
}
