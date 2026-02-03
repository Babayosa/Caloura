import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // Debounce settings saves to avoid hammering UserDefaults
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 300_000_000 // 300ms

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
        static let launchAtLogin = "launchAtLogin"
        static let checkForUpdatesAutomatically = "checkForUpdatesAutomatically"
        static let firstLaunchDate = "firstLaunchDate"
        static let licenseKey = "licenseKey"
        static let isLicenseActivated = "isLicenseActivated"
    }

    @Published var saveDirectory: String {
        didSet { debouncedSave() }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet { debouncedSave() }
    }

    @Published var autoSaveToDisk: Bool {
        didSet { debouncedSave() }
    }

    @Published var smartCropEnabled: Bool {
        didSet { debouncedSave() }
    }

    @Published var playCaptureSound: Bool {
        didSet { debouncedSave() }
    }

    @Published var activePreset: String {
        didSet { debouncedSave() }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { debouncedSave() }
    }

    @Published var imageFormat: String {
        didSet { debouncedSave() }
    }

    @Published var autoContextDetection: Bool {
        didSet { debouncedSave() }
    }

    @Published var launchAtLogin: Bool {
        didSet { debouncedSave() }
    }

    @Published var checkForUpdatesAutomatically: Bool {
        didSet { debouncedSave() }
    }

    @Published var firstLaunchDate: Date {
        didSet { debouncedSave() }
    }

    @Published var licenseKey: String {
        didSet { debouncedSave() }
    }

    @Published var isLicenseActivated: Bool {
        didSet { debouncedSave() }
    }

    var saveDirectoryURL: URL {
        URL(fileURLWithPath: saveDirectory)
    }

    private static var defaultSaveDirectory: String {
        guard let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            return NSHomeDirectory() + "/Pictures/Caloura"
        }
        return pictures.appendingPathComponent("Caloura").path
    }

    // MARK: - Debounced Save

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: saveDebounceInterval)
            guard !Task.isCancelled else { return }
            saveAllSettings()
        }
    }

    private func saveAllSettings() {
        defaults.set(saveDirectory, forKey: Keys.saveDirectory)
        defaults.set(autoCopyToClipboard, forKey: Keys.autoCopyToClipboard)
        defaults.set(autoSaveToDisk, forKey: Keys.autoSaveToDisk)
        defaults.set(smartCropEnabled, forKey: Keys.smartCropEnabled)
        defaults.set(playCaptureSound, forKey: Keys.playCaptureSound)
        defaults.set(activePreset, forKey: Keys.activePreset)
        defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding)
        defaults.set(imageFormat, forKey: Keys.imageFormat)
        defaults.set(autoContextDetection, forKey: Keys.autoContextDetection)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(checkForUpdatesAutomatically, forKey: Keys.checkForUpdatesAutomatically)
        defaults.set(firstLaunchDate, forKey: Keys.firstLaunchDate)
        defaults.set(licenseKey, forKey: Keys.licenseKey)
        defaults.set(isLicenseActivated, forKey: Keys.isLicenseActivated)
    }

    // MARK: - Init

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
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.checkForUpdatesAutomatically = defaults.object(forKey: Keys.checkForUpdatesAutomatically) as? Bool ?? true

        // Trial clock: set on first launch, immutable thereafter
        if let stored = defaults.object(forKey: Keys.firstLaunchDate) as? Date {
            self.firstLaunchDate = stored
        } else {
            let now = Date()
            self.firstLaunchDate = now
            defaults.set(now, forKey: Keys.firstLaunchDate)
        }
        self.licenseKey = defaults.string(forKey: Keys.licenseKey) ?? ""
        self.isLicenseActivated = defaults.bool(forKey: Keys.isLicenseActivated)
    }
}
