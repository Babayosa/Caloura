import Foundation
import SwiftUI
import os.log

@MainActor
final class AppSettings: ObservableObject {
    typealias LegacyLicenseMigration = () -> LegacyKeychainReadResult

    static let shared = AppSettings()
    nonisolated private static let keychainService = Bundle.main.bundleIdentifier ?? "com.caloura.app"

    private let defaults: UserDefaults
    private let legacyLicenseMigration: LegacyLicenseMigration
    private let logger = Logger(subsystem: "com.caloura.app", category: "AppSettings")

    // Debounce settings saves to avoid hammering UserDefaults.
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
        static let hasSeenWelcome = "hasSeenWelcome"
        static let hasAttemptedLegacyLicenseMigration = "hasAttemptedLegacyLicenseMigration"
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
        didSet { persistLicenseState() }
    }

    @Published var isLicenseActivated: Bool {
        didSet {
            persistLicenseState()
            debouncedSave()
        }
    }

    @Published var hasSeenWelcome: Bool {
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

    nonisolated private static func defaultLegacyLicenseMigration() -> LegacyKeychainReadResult {
        KeychainHelper.readLegacyStringNonInteractive(service: keychainService, account: Keys.licenseKey)
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
        defaults.set(isLicenseActivated, forKey: Keys.isLicenseActivated)
        defaults.set(hasSeenWelcome, forKey: Keys.hasSeenWelcome)
    }

    func persistLicenseState() {
        let normalized = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            defaults.removeObject(forKey: Keys.licenseKey)
        } else {
            defaults.set(normalized, forKey: Keys.licenseKey)
        }
        defaults.set(isLicenseActivated, forKey: Keys.isLicenseActivated)
    }

    /// Best-effort migration path for legacy keychain-backed license keys.
    /// This is non-interactive and never shows authentication UI.
    func migrateLegacyLicenseSilentlyIfAvailable() {
        guard !defaults.bool(forKey: Keys.hasAttemptedLegacyLicenseMigration) else {
            return
        }
        defer {
            defaults.set(true, forKey: Keys.hasAttemptedLegacyLicenseMigration)
        }

        guard licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        switch legacyLicenseMigration() {
        case .success(let migratedKey):
            let normalized = migratedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            licenseKey = normalized
            if !isLicenseActivated {
                isLicenseActivated = true
            }
            KeychainHelper.deleteLegacyItem(service: Self.keychainService, account: Keys.licenseKey)
            logger.info("Migrated legacy license key without prompting user.")
        case .notFound:
            break
        case .interactionRequired:
            logger.info("Skipped legacy license migration: keychain interaction required.")
        case .failure(let status):
            logger.error("Failed legacy license migration read: status=\(status)")
        }
    }

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        legacyLicenseMigration: @escaping LegacyLicenseMigration = AppSettings.defaultLegacyLicenseMigration
    ) {
        self.defaults = defaults
        self.legacyLicenseMigration = legacyLicenseMigration

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

        // Trial clock: set on first launch, immutable thereafter.
        if let stored = defaults.object(forKey: Keys.firstLaunchDate) as? Date {
            self.firstLaunchDate = stored
        } else {
            let now = Date()
            self.firstLaunchDate = now
            defaults.set(now, forKey: Keys.firstLaunchDate)
        }

        self.licenseKey = defaults.string(forKey: Keys.licenseKey) ?? ""
        self.isLicenseActivated = defaults.bool(forKey: Keys.isLicenseActivated)
        self.hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)

        migrateLegacyLicenseSilentlyIfAvailable()
        persistLicenseState()
    }
}
