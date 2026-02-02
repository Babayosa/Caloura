import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let saveDirectory = "saveDirectory"
        static let autoCopyToClipboard = "autoCopyToClipboard"
        static let autoSaveToDisk = "autoSaveToDisk"
        static let smartCropEnabled = "smartCropEnabled"
        static let playCaptureSound = "playCaptureSound"
        static let activePreset = "activePreset"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let imageFormat = "imageFormat"
        static let autoContextDetection = "autoContextDetection"
    }

    @Published var saveDirectory: String {
        didSet { defaults.set(saveDirectory, forKey: Keys.saveDirectory) }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet { defaults.set(autoCopyToClipboard, forKey: Keys.autoCopyToClipboard) }
    }

    @Published var autoSaveToDisk: Bool {
        didSet { defaults.set(autoSaveToDisk, forKey: Keys.autoSaveToDisk) }
    }

    @Published var smartCropEnabled: Bool {
        didSet { defaults.set(smartCropEnabled, forKey: Keys.smartCropEnabled) }
    }

    @Published var playCaptureSound: Bool {
        didSet { defaults.set(playCaptureSound, forKey: Keys.playCaptureSound) }
    }

    @Published var activePreset: String {
        didSet { defaults.set(activePreset, forKey: Keys.activePreset) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published var imageFormat: String {
        didSet { defaults.set(imageFormat, forKey: Keys.imageFormat) }
    }

    @Published var autoContextDetection: Bool {
        didSet { defaults.set(autoContextDetection, forKey: Keys.autoContextDetection) }
    }

    var saveDirectoryURL: URL {
        URL(fileURLWithPath: saveDirectory)
    }

    private static var defaultSaveDirectory: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("Caloura").path
    }

    private init() {
        let defaultDir = Self.defaultSaveDirectory
        self.saveDirectory = defaults.string(forKey: Keys.saveDirectory) ?? defaultDir
        self.autoCopyToClipboard = defaults.object(forKey: Keys.autoCopyToClipboard) as? Bool ?? true
        self.autoSaveToDisk = defaults.object(forKey: Keys.autoSaveToDisk) as? Bool ?? true
        self.smartCropEnabled = defaults.object(forKey: Keys.smartCropEnabled) as? Bool ?? true
        self.playCaptureSound = defaults.object(forKey: Keys.playCaptureSound) as? Bool ?? false
        self.activePreset = defaults.string(forKey: Keys.activePreset) ?? "Quick Capture"
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.imageFormat = defaults.string(forKey: Keys.imageFormat) ?? "png"
        self.autoContextDetection = defaults.object(forKey: Keys.autoContextDetection) as? Bool ?? true
    }
}
