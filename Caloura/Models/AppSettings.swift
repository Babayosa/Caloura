import KeyboardShortcuts
import SwiftUI
import os.log

enum ContextualOnboardingTip: String, CaseIterable {
    case history
    case edit
    case share

    fileprivate var defaultsKey: String {
        "contextualOnboardingTip.\(rawValue)"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    typealias LegacyLicenseMigration = @Sendable () -> LegacyKeychainReadResult

    static let shared = AppSettings()
    nonisolated static let keychainService = Bundle.main.bundleIdentifier ?? "com.caloura.app"

    let defaults: UserDefaults
    let legacyLicenseMigration: LegacyLicenseMigration

    // Debounce settings saves to avoid hammering UserDefaults.
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 300_000_000 // 300ms
    var legacyMigrationTask: Task<Void, Never>?

    enum Keys {
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
        static let licenseEntitlement = "licenseEntitlement"
        static let isLicenseActivated = "isLicenseActivated"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let hasAttemptedLegacyLicenseMigration = "hasAttemptedLegacyLicenseMigration"
        static let licenseKeyMigrated = "licenseKeyMigrated"
        static let lastLicenseValidationDate = "lastLicenseValidationDate"
        static let furthestDateSeen = "furthestDateSeen"
        static let autoClearClipboard = "autoClearClipboard"
        static let autoDetectPII = "autoDetectPII"
        static let beautifyThemeName = "beautifyThemeName"
        static let smartMetadataEnabled = "smartMetadataEnabled"
        static let semanticSearchEnabled = "semanticSearchEnabled"
        static let lowProfileCaptureEnabled = "lowProfileCaptureEnabled"
        static let anonymousDiagnosticsEnabled = "anonymousDiagnosticsEnabled"
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

    @Published var isLicenseActivated: Bool

    /// Resolves once the license subsystem has finished decrypting persisted
    /// state off the launch thread. Callers that depend on `licenseKey` /
    /// `isLicenseActivated` being authoritative (e.g. trial gating, nag UI)
    /// should `await` this before reading. `nil` means already resolved.
    var licenseReady: Task<Void, Never>?

    @Published var hasSeenWelcome: Bool {
        didSet { debouncedSave() }
    }

    @Published var autoClearClipboard: Bool {
        didSet { debouncedSave() }
    }

    @Published var autoDetectPII: Bool {
        didSet { debouncedSave() }
    }

    @Published var beautifyThemeName: String {
        didSet { debouncedSave() }
    }

    @Published var smartMetadataEnabled: Bool {
        didSet { debouncedSave() }
    }

    @Published var semanticSearchEnabled: Bool {
        didSet { debouncedSave() }
    }

    @Published var lowProfileCaptureEnabled: Bool {
        didSet { debouncedSave() }
    }

    @Published var anonymousDiagnosticsEnabled: Bool {
        didSet { debouncedSave() }
    }

    var furthestDateSeen: Date? {
        get { defaults.object(forKey: Keys.furthestDateSeen) as? Date }
        set { defaults.set(newValue, forKey: Keys.furthestDateSeen) }
    }

    func hasSeenContextualTip(_ tip: ContextualOnboardingTip) -> Bool {
        defaults.bool(forKey: tip.defaultsKey)
    }

    func markContextualTipSeen(_ tip: ContextualOnboardingTip) {
        defaults.set(true, forKey: tip.defaultsKey)
    }

    var licenseEntitlement: LicenseEntitlement? {
        didSet {
            syncDerivedLicenseState()
            persistLicenseState()
        }
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

    func saveAllSettings() {
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
        defaults.set(autoClearClipboard, forKey: Keys.autoClearClipboard)
        defaults.set(autoDetectPII, forKey: Keys.autoDetectPII)
        defaults.set(beautifyThemeName, forKey: Keys.beautifyThemeName)
        defaults.set(smartMetadataEnabled, forKey: Keys.smartMetadataEnabled)
        defaults.set(semanticSearchEnabled, forKey: Keys.semanticSearchEnabled)
        defaults.set(lowProfileCaptureEnabled, forKey: Keys.lowProfileCaptureEnabled)
        defaults.set(anonymousDiagnosticsEnabled, forKey: Keys.anonymousDiagnosticsEnabled)
    }

    // MARK: - HotKey Defaults Migration

    private func migrateHotKeyDefaultsIfNeeded() {
        if !defaults.bool(forKey: "hotKeyDefaultsMigratedV2") {
            defaults.set(true, forKey: "hotKeyDefaultsMigratedV2")
            // Only reset shortcuts that still match the old Cmd+Shift defaults.
            // User-customized shortcuts are left untouched.
            resetShortcutIfMatchesOldDefault(.captureArea, oldModifiers: 768, oldKeyCode: 21)
            resetShortcutIfMatchesOldDefault(.captureWindow, oldModifiers: 768, oldKeyCode: 23)
            resetShortcutIfMatchesOldDefault(.captureFullscreen, oldModifiers: 768, oldKeyCode: 20)
        }

        if !defaults.bool(forKey: "hotKeyDefaultsMigratedV3") {
            defaults.set(true, forKey: "hotKeyDefaultsMigratedV3")
            // captureArea default moved from Control+Option+4 to Control+Option+C.
            // Carbon modifiers: controlKey (4096) + optionKey (2048) = 6144.
            // Carbon keyCode for "4" = 21.
            resetShortcutIfMatchesOldDefault(.captureArea, oldModifiers: 6144, oldKeyCode: 21)
        }

        if !defaults.bool(forKey: "hotKeyDefaultsMigratedV4") {
            defaults.set(true, forKey: "hotKeyDefaultsMigratedV4")
            // captureWindow default moved from Control+Option+5 to Control+Option+W.
            // captureFullscreen default moved from Control+Option+3 to Control+Option+F.
            // Carbon keyCodes: "5" = 23, "3" = 20. Modifiers 6144 as above.
            resetShortcutIfMatchesOldDefault(.captureWindow, oldModifiers: 6144, oldKeyCode: 23)
            resetShortcutIfMatchesOldDefault(.captureFullscreen, oldModifiers: 6144, oldKeyCode: 20)
        }
    }

    private func resetShortcutIfMatchesOldDefault(
        _ name: KeyboardShortcuts.Name,
        oldModifiers: Int,
        oldKeyCode: Int
    ) {
        let key = "KeyboardShortcuts_\(name.rawValue)"
        guard let jsonString = defaults.string(forKey: key),
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedModifiers = dict["carbonModifiers"] as? Int,
              let storedKeyCode = dict["carbonKeyCode"] as? Int,
              storedModifiers == oldModifiers,
              storedKeyCode == oldKeyCode
        else { return }
        KeyboardShortcuts.reset(name)
    }

    // MARK: - Init

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            legacyLicenseMigration: {
                AppSettings.defaultLegacyLicenseMigration()
            }
        )
    }

    init(
        defaults: UserDefaults,
        legacyLicenseMigration: @escaping LegacyLicenseMigration
    ) {
        self.defaults = defaults
        self.legacyLicenseMigration = legacyLicenseMigration

        let defaultDir = Self.defaultSaveDirectory
        self.saveDirectory = defaults.string(forKey: Keys.saveDirectory) ?? defaultDir
        self.autoCopyToClipboard = defaults.object(forKey: Keys.autoCopyToClipboard) as? Bool ?? true
        self.autoSaveToDisk = defaults.object(forKey: Keys.autoSaveToDisk) as? Bool ?? false
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

        self.licenseKey = ""
        self.isLicenseActivated = false
        self.hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
        self.autoClearClipboard = defaults.object(forKey: Keys.autoClearClipboard) as? Bool ?? false
        self.autoDetectPII = defaults.object(forKey: Keys.autoDetectPII) as? Bool ?? false
        self.beautifyThemeName = defaults.string(forKey: Keys.beautifyThemeName) ?? "Clean"
        self.smartMetadataEnabled = defaults.object(forKey: Keys.smartMetadataEnabled) as? Bool ?? true
        self.semanticSearchEnabled = defaults.object(forKey: Keys.semanticSearchEnabled) as? Bool ?? true
        self.lowProfileCaptureEnabled = defaults.object(forKey: Keys.lowProfileCaptureEnabled) as? Bool ?? false
        self.licenseEntitlement = nil
        self.anonymousDiagnosticsEnabled = defaults.object(
            forKey: Keys.anonymousDiagnosticsEnabled
        ) as? Bool ?? false

        migrateHotKeyDefaultsIfNeeded()
        activateLicenseSubsystem()
    }
}
