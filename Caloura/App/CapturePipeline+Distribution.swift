import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ScreenshotArtifactCoordinator {
    static let shared = ScreenshotArtifactCoordinator()

    typealias SaveFileFn = (ProcessedScreenshot, String, String?, String) async throws -> URL
    typealias OverwriteImageFn = (CGImage, URL, String) async throws -> Void
    typealias PromptForSaveURLFn = @MainActor (String) -> URL?

    private let appState: AppState
    private let settings: AppSettings
    private let saveFile: SaveFileFn
    private let overwriteImage: OverwriteImageFn
    private let promptForSaveURL: PromptForSaveURLFn
    private var activeSaveTasks: [UUID: Task<URL, Error>] = [:]

    private init() {
        self.appState = AppState.shared
        self.settings = AppSettings.shared
        self.saveFile = { screenshot, baseDirectory, subfolder, imageFormat in
            try await FileOrganizer.save(
                screenshot,
                baseDirectory: baseDirectory,
                subfolder: subfolder,
                imageFormat: imageFormat
            )
        }
        self.overwriteImage = { cgImage, url, imageFormat in
            try await FileOrganizer.overwrite(cgImage: cgImage, at: url, imageFormat: imageFormat)
        }
        self.promptForSaveURL = { suggestedName in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff]
            panel.nameFieldStringValue = suggestedName
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }

    init(
        appState: AppState,
        settings: AppSettings,
        saveFile: @escaping SaveFileFn,
        overwriteImage: @escaping OverwriteImageFn,
        promptForSaveURL: @escaping PromptForSaveURLFn
    ) {
        self.appState = appState
        self.settings = settings
        self.saveFile = saveFile
        self.overwriteImage = overwriteImage
        self.promptForSaveURL = promptForSaveURL
    }

    func saveCapture(
        _ screenshot: ProcessedScreenshot,
        subfolder: String? = nil
    ) async throws -> URL {
        if let existingURL = screenshot.filePath {
            persistSavedScreenshot(screenshot, at: existingURL)
            return existingURL
        }

        if let activeTask = activeSaveTasks[screenshot.id] {
            return try await activeTask.value
        }

        let baseDirectory = settings.saveDirectory
        let imageFormat = settings.imageFormat
        let resolvedSubfolder = subfolder ?? defaultSubfolder(for: screenshot)

        let task = Task<URL, Error> {
            let url = try await saveFile(screenshot, baseDirectory, resolvedSubfolder, imageFormat)
            await MainActor.run {
                self.persistSavedScreenshot(screenshot, at: url)
            }
            return url
        }

        activeSaveTasks[screenshot.id] = task
        defer { activeSaveTasks[screenshot.id] = nil }
        return try await task.value
    }

    func saveDerivedCapture(
        _ cgImage: CGImage,
        basedOn screenshot: ProcessedScreenshot,
        suggestedSuffix: String
    ) async throws -> ProcessedScreenshot {
        let updatedScreenshot: ProcessedScreenshot

        if let existingURL = screenshot.filePath {
            try await overwriteImage(
                cgImage,
                existingURL,
                FileOrganizer.imageFormat(for: existingURL)
            )
            updatedScreenshot = screenshot.replacingImage(
                cgImage,
                filePath: existingURL,
                fileName: existingURL.lastPathComponent
            )
        } else {
            let suggestedName = suggestedFileName(
                for: screenshot,
                suffix: suggestedSuffix,
                imageFormat: settings.imageFormat
            )
            guard let destinationURL = promptForSaveURL(suggestedName) else {
                throw CancellationError()
            }
            try await overwriteImage(
                cgImage,
                destinationURL,
                FileOrganizer.imageFormat(for: destinationURL)
            )
            updatedScreenshot = screenshot.replacingImage(
                cgImage,
                filePath: destinationURL,
                fileName: destinationURL.lastPathComponent
            )
        }

        appState.lastScreenshot = updatedScreenshot
        appState.syncProcessedScreenshot(updatedScreenshot)
        return updatedScreenshot
    }

    private func persistSavedScreenshot(_ screenshot: ProcessedScreenshot, at url: URL) {
        screenshot.filePath = url
        screenshot.fileName = url.lastPathComponent
        appState.lastScreenshot = screenshot
        appState.syncProcessedScreenshot(screenshot)
    }

    private func defaultSubfolder(for screenshot: ProcessedScreenshot) -> String? {
        guard let presetName = screenshot.presetName else { return nil }
        return PresetManager.shared.preset(named: presetName)?.subfolder
    }

    private func suggestedFileName(
        for screenshot: ProcessedScreenshot,
        suffix: String,
        imageFormat: String
    ) -> String {
        let ext = {
            switch imageFormat {
            case "jpeg": "jpeg"
            case "tiff": "tiff"
            default: "png"
            }
        }()

        let baseName: String
        if screenshot.fileName.isEmpty {
            baseName = FileOrganizer.generateFileName(
                for: screenshot.context,
                imageFormat: imageFormat
            ).deletingPathExtension
        } else {
            baseName = screenshot.fileName.deletingPathExtension
        }

        return "\(baseName)-\(suffix).\(ext)"
    }
}

// MARK: - Distribution Actions

extension CapturePipeline {

    func performQuickAction(
        _ action: CaptureQuickAction,
        for screenshot: ProcessedScreenshot
    ) {
        appState.lastScreenshot = screenshot

        switch action {
        case .copy:
            Task {
                do {
                    try await ClipboardManager.copyImage(screenshot)
                    await MainActor.run {
                        OnboardingTipsController.shared.showIfNeeded(.share)
                        self.appState.statusMessage = "Copied image"
                    }
                } catch {
                    await MainActor.run {
                        self.appState.statusMessage = error.localizedDescription
                    }
                }
            }
        case .save:
            Task {
                do {
                    _ = try await ScreenshotArtifactCoordinator.shared.saveCapture(screenshot)
                    await MainActor.run {
                        OnboardingTipsController.shared.showIfNeeded(.share)
                        let phase = self.appState.previewPhase(for: screenshot.id)
                        let alreadyEnriched = phase == .enrichmentPending
                            || phase == .enrichmentComplete
                        if !alreadyEnriched {
                            self.appState.setCapturePreviewPhase(
                                .enrichmentPending,
                                for: screenshot.id
                            )
                            self.addToHistoryWithOCR(screenshot)
                        }
                        self.appState.statusMessage = "Saved to disk"
                    }
                } catch {
                    await MainActor.run {
                        self.appState.statusMessage = "Save failed: \(error.localizedDescription)"
                    }
                }
            }
        case .markdown:
            do {
                try ClipboardManager.copyAsMarkdown(screenshot)
                OnboardingTipsController.shared.showIfNeeded(.share)
                appState.statusMessage = "Copied as Markdown"
            } catch {
                appState.statusMessage = error.localizedDescription
            }
        case .citation:
            do {
                try ClipboardManager.copyWithCitation(screenshot)
                OnboardingTipsController.shared.showIfNeeded(.share)
                appState.statusMessage = "Copied with citation"
            } catch {
                appState.statusMessage = error.localizedDescription
            }
        case .annotate:
            AppCommandRouter.shared.dispatch(.annotateLastCapture)
        case .pin:
            AppCommandRouter.shared.dispatch(.pinScreenshot)
        case .beautify:
            AppCommandRouter.shared.dispatch(.beautifyLastCapture)
        case .redact:
            AppCommandRouter.shared.dispatch(.redactLastCapture)
        case .dismiss:
            QuickAccessOverlay.shared.dismiss()
        }
    }

    func saveLastCapture() {
        guard let screenshot = appState.lastScreenshot else {
            appState.statusMessage = "No screenshot available"
            return
        }
        performQuickAction(.save, for: screenshot)
    }

    func copyLastImage() {
        guard let screenshot = appState.lastScreenshot else {
            appState.statusMessage = "No screenshot available"
            return
        }
        Task {
            do {
                try await ClipboardManager.copyImage(screenshot)
                await MainActor.run {
                    OnboardingTipsController.shared.showIfNeeded(.share)
                    self.appState.statusMessage = "Copied image"
                }
            } catch {
                await MainActor.run {
                    self.appState.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func copyLastAsMarkdown() {
        guard let screenshot = appState.lastScreenshot else { return }
        do {
            try ClipboardManager.copyAsMarkdown(screenshot)
            OnboardingTipsController.shared.showIfNeeded(.share)
            appState.statusMessage = "Copied as Markdown"
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    func copyLastWithCitation() {
        guard let screenshot = appState.lastScreenshot else { return }
        do {
            try ClipboardManager.copyWithCitation(screenshot)
            OnboardingTipsController.shared.showIfNeeded(.share)
            appState.statusMessage = "Copied with citation"
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    func copyLastOCRText() {
        guard let lastItem = appState.recentScreenshots.first,
              let text = lastItem.ocrText, !text.isEmpty else {
            appState.statusMessage = "No OCR text available"
            return
        }
        do {
            try ClipboardManager.copyOCRText(text)
            appState.statusMessage = "Copied OCR text"
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}
