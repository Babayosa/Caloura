import Foundation

@MainActor
final class CaptureDistributionService {
    typealias CopyToClipboardFn = (ProcessedScreenshot, CopyMode) async throws -> Void
    typealias SaveCaptureFn = @MainActor (ProcessedScreenshot) async throws -> URL
    typealias PlaySoundFn = () -> Void
    typealias EnqueueEnrichmentFn = @MainActor (ProcessedScreenshot) -> Void
    typealias DispatchCommandFn = @MainActor (AppCommand) -> Void
    typealias ShowTipFn = @MainActor (ContextualOnboardingTip) -> Void
    typealias DismissQuickAccessFn = @MainActor () -> Void

    private let appState: AppState
    private let copyToClipboard: CopyToClipboardFn
    private let saveCapture: SaveCaptureFn
    private let playSound: PlaySoundFn
    private let enqueueEnrichment: EnqueueEnrichmentFn
    private let dispatchCommand: DispatchCommandFn
    private let showTip: ShowTipFn
    private let dismissQuickAccess: DismissQuickAccessFn

    init(
        appState: AppState,
        copyToClipboard: @escaping CopyToClipboardFn,
        saveCapture: @escaping SaveCaptureFn,
        playSound: @escaping PlaySoundFn,
        enqueueEnrichment: @escaping EnqueueEnrichmentFn,
        dispatchCommand: @escaping DispatchCommandFn,
        showTip: @escaping ShowTipFn,
        dismissQuickAccess: @escaping DismissQuickAccessFn
    ) {
        self.appState = appState
        self.copyToClipboard = copyToClipboard
        self.saveCapture = saveCapture
        self.playSound = playSound
        self.enqueueEnrichment = enqueueEnrichment
        self.dispatchCommand = dispatchCommand
        self.showTip = showTip
        self.dismissQuickAccess = dismissQuickAccess
    }

    func copy(_ screenshot: ProcessedScreenshot, using mode: CopyMode) async throws {
        try await copyToClipboard(screenshot, mode)
    }

    func playCaptureSound() {
        playSound()
    }

    func performQuickAction(
        _ action: CaptureQuickAction,
        for screenshot: ProcessedScreenshot
    ) {
        appState.lastScreenshot = screenshot

        switch action {
        case .copy:
            triggerCopy(
                screenshot,
                using: .image,
                successMessage: "Copied image",
                showShareTip: true
            )
        case .save:
            triggerSave(
                screenshot,
                successMessage: "Saved to disk",
                showShareTip: true
            )
        case .markdown:
            triggerCopy(
                screenshot,
                using: .markdown,
                successMessage: "Copied as Markdown",
                showShareTip: true
            )
        case .citation:
            triggerCopy(
                screenshot,
                using: .citation,
                successMessage: "Copied with citation",
                showShareTip: true
            )
        case .annotate:
            dispatchCommand(.annotateLastCapture)
        case .pin:
            dispatchCommand(.pinScreenshot)
        case .beautify:
            dispatchCommand(.beautifyLastCapture)
        case .redact:
            dispatchCommand(.redactLastCapture)
        case .dismiss:
            dismissQuickAccess()
        }
    }

    func saveLastCapture() {
        guard let screenshot = appState.lastScreenshot else {
            appState.setStatusMessage("No screenshot available")
            return
        }

        triggerSave(
            screenshot,
            successMessage: "Saved to disk",
            showShareTip: true
        )
    }

    func copyLastImage() {
        guard let screenshot = appState.lastScreenshot else {
            appState.setStatusMessage("No screenshot available")
            return
        }

        triggerCopy(
            screenshot,
            using: .image,
            successMessage: "Copied image",
            showShareTip: false
        )
    }

    func copyLastAsMarkdown() {
        guard let screenshot = appState.lastScreenshot else { return }

        triggerCopy(
            screenshot,
            using: .markdown,
            successMessage: "Copied as Markdown",
            showShareTip: true
        )
    }

    func copyLastWithCitation() {
        guard let screenshot = appState.lastScreenshot else { return }

        triggerCopy(
            screenshot,
            using: .citation,
            successMessage: "Copied with citation",
            showShareTip: true
        )
    }

    func copyLastOCRText() {
        guard let lastItem = appState.recentScreenshots.first,
              let text = lastItem.ocrText,
              !text.isEmpty else {
            appState.setStatusMessage("No OCR text available")
            return
        }

        do {
            try ClipboardManager.copyOCRText(text)
            appState.setStatusMessage("Copied OCR text")
        } catch {
            appState.setStatusMessage(error.localizedDescription)
        }
    }

    private func triggerCopy(
        _ screenshot: ProcessedScreenshot,
        using mode: CopyMode,
        successMessage: String,
        showShareTip: Bool
    ) {
        Task {
            do {
                try await copy(screenshot, using: mode)
                await MainActor.run {
                    if showShareTip {
                        showTip(.share)
                    }
                    appState.setStatusMessage(successMessage)
                }
            } catch {
                await MainActor.run {
                    appState.setStatusMessage(error.localizedDescription)
                }
            }
        }
    }

    private func triggerSave(
        _ screenshot: ProcessedScreenshot,
        successMessage: String,
        showShareTip: Bool
    ) {
        Task {
            do {
                _ = try await saveCapture(screenshot)
                await MainActor.run {
                    if showShareTip {
                        showTip(.share)
                    }
                    let phase = appState.previewPhase(for: screenshot.id)
                    let hasOCRText = !(screenshot.ocrText?.isEmpty ?? true)
                    let alreadyEnriched = phase == .enrichmentPending
                        || phase == .enrichmentComplete
                        || hasOCRText
                    if !alreadyEnriched {
                        appState.setCapturePreviewPhase(
                            .enrichmentPending,
                            for: screenshot.id
                        )
                        enqueueEnrichment(screenshot)
                    }
                    appState.setStatusMessage(successMessage)
                }
            } catch {
                await MainActor.run {
                    appState.setStatusMessage(
                        "Save failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}
