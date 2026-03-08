import AppKit
import os.log

@MainActor
final class AppCommandController {
    private let onboardingController: OnboardingWindowController
    private let historyController: HistoryWindowController
    private let annotationController: AnnotationWindowController
    private let annotationLogger = Logger(
        subsystem: "com.caloura.app",
        category: "Annotation"
    )

    init(
        onboardingController: OnboardingWindowController,
        historyController: HistoryWindowController,
        annotationController: AnnotationWindowController
    ) {
        self.onboardingController = onboardingController
        self.historyController = historyController
        self.annotationController = annotationController
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
        default:
            return false
        }

        return true
    }

    private func handleDistributionCommand(_ command: AppCommand) -> Bool {
        switch command {
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
        default:
            return false
        }

        return true
    }

    private func handleWindowCommand(_ command: AppCommand) {
        switch command {
        case .showHistory:
            OnboardingTipsController.shared.showIfNeeded(.history)
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
        OnboardingTipsController.shared.showIfNeeded(.edit)
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
