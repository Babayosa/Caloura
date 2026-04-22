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
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
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
            case "heic": "heic"
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

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}
