import SwiftUI
import os.log

enum ContextualOnboardingTip: String, CaseIterable {
    case history
    case edit
    case scroll
    case share

    fileprivate var defaultsKey: String {
        "contextualOnboardingTip.\(rawValue)"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    typealias LegacyLicenseMigration = @Sendable () -> LegacyKeychainReadResult

    static let shared = AppSettings()
    nonisolated private static let keychainService = Bundle.main.bundleIdentifier ?? "com.caloura.app"

    private let defaults: UserDefaults
    private let legacyLicenseMigration: LegacyLicenseMigration
    private let logger = Logger(subsystem: "com.caloura.app", category: "AppSettings")

    // Debounce settings saves to avoid hammering UserDefaults.
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 300_000_000 // 300ms
    private var legacyMigrationTask: Task<Void, Never>?

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
        static let scrollSpeed = "scrollSpeed"
        static let scrollMaxHeight = "scrollMaxHeight"
        static let scrollStickyHeaders = "scrollStickyHeaders"
        static let scrollToTop = "scrollToTop"
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

    @Published private(set) var isLicenseActivated: Bool

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

    @Published var scrollSpeed: Int {
        didSet { debouncedSave() }
    }

    @Published var scrollMaxHeight: Int {
        didSet { debouncedSave() }
    }

    @Published var scrollStickyHeaders: Bool {
        didSet { debouncedSave() }
    }

    @Published var scrollToTop: Bool {
        didSet { debouncedSave() }
    }

    var lastLicenseValidationDate: Date? {
        get { defaults.object(forKey: Keys.lastLicenseValidationDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastLicenseValidationDate) }
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

    private var licenseEntitlement: LicenseEntitlement? {
        didSet {
            syncDerivedLicenseState()
            persistLicenseState()
        }
    }

    var currentLicenseEntitlement: LicenseEntitlement? {
        licenseEntitlement
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

    private enum LegacyLicenseMigrationOutcome: Sendable {
        case notFound
        case migrated(String)
        case interactionRequired
        case failure(OSStatus)
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
        defaults.set(scrollSpeed, forKey: Keys.scrollSpeed)
        defaults.set(scrollMaxHeight, forKey: Keys.scrollMaxHeight)
        defaults.set(scrollStickyHeaders, forKey: Keys.scrollStickyHeaders)
        defaults.set(scrollToTop, forKey: Keys.scrollToTop)
    }

    func persistLicenseState() {
        let normalized = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            defaults.removeObject(forKey: Keys.licenseKey)
        } else {
            if let encrypted = Self.encryptLicenseKey(normalized) {
                defaults.set(encrypted, forKey: Keys.licenseKey)
                defaults.set(true, forKey: Keys.licenseKeyMigrated)
            } else {
                logger.error("Failed to encrypt license key — not persisting")
            }
        }

        if let licenseEntitlement {
            if let encryptedEntitlement = Self.encryptLicenseEntitlement(licenseEntitlement) {
                defaults.set(encryptedEntitlement, forKey: Keys.licenseEntitlement)
            } else {
                logger.error("Failed to encrypt license entitlement — not persisting")
            }
        } else {
            defaults.removeObject(forKey: Keys.licenseEntitlement)
        }

        // Mirror the derived state for compatibility, but do not trust this value on load.
        defaults.set(isLicenseActivated, forKey: Keys.isLicenseActivated)
    }

    // MARK: - License Key Encryption

    nonisolated private static func encryptLicenseKey(_ plaintext: String) -> Data? {
        guard let data = plaintext.data(using: .utf8) else { return nil }
        return try? HistoryCrypto.encrypt(data, purpose: "license-key")
    }

    nonisolated private static func encryptLicenseEntitlement(_ entitlement: LicenseEntitlement) -> Data? {
        guard let data = try? JSONEncoder().encode(entitlement) else { return nil }
        return try? HistoryCrypto.encrypt(data, purpose: "license-artifact")
    }

    nonisolated private static func decryptLicenseKey(
        _ stored: Any?,
        migrated: Bool
    ) -> String? {
        if let data = stored as? Data {
            // Encrypted format
            let decrypted = (
                (try? HistoryCrypto.decrypt(data, purpose: "license-key"))
                ?? (try? HistoryCrypto.decrypt(data))
            )
            guard let decrypted,
                  let string = String(data: decrypted, encoding: .utf8) else {
                return nil
            }
            return string
        }
        // Legacy plaintext format — only accept if encryption has never succeeded
        if migrated {
            return nil
        }
        return stored as? String
    }

    nonisolated private static func decryptLicenseEntitlement(_ stored: Any?) -> LicenseEntitlement? {
        guard let data = stored as? Data,
              let decrypted = try? HistoryCrypto.decrypt(data, purpose: "license-artifact") else {
            return nil
        }
        return try? JSONDecoder().decode(LicenseEntitlement.self, from: decrypted)
    }

    private func syncDerivedLicenseState(referenceDate: Date = Date()) {
        isLicenseActivated = licenseEntitlement?.isCurrentlyValid(at: referenceDate) ?? false
    }

    func updateLicenseEntitlement(_ entitlement: LicenseEntitlement?) {
        licenseEntitlement = entitlement
        lastLicenseValidationDate = entitlement?.validatedAt
    }

    private func migrateLegacyActivationStateIfNeeded() {
        guard licenseEntitlement == nil,
              defaults.bool(forKey: Keys.isLicenseActivated) else {
            return
        }

        let normalized = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let validatedAt = lastLicenseValidationDate ?? Date()
        let now = Date()
        let effectiveValidation = max(validatedAt, now)
        licenseEntitlement = LicenseEntitlement(
            claims: LicenseEntitlementClaims(
                productID: Bundle.main.bundleIdentifier ?? "com.caloura.app",
                licenseID: normalized,
                issuedAt: validatedAt,
                refreshAfter: validatedAt,
                expiresAt: effectiveValidation.addingTimeInterval(7 * 86_400),
                featureFlags: [:]
            ),
            source: .legacyMigration,
            token: nil,
            signature: nil,
            validatedAt: validatedAt
        )
    }

    /// Best-effort migration path for legacy keychain-backed license keys.
    /// This is non-interactive, runs off-main, and never shows authentication UI.
    func migrateLegacyLicenseSilentlyIfAvailable() {
        guard !defaults.bool(forKey: Keys.hasAttemptedLegacyLicenseMigration) else {
            return
        }
        guard licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.set(true, forKey: Keys.hasAttemptedLegacyLicenseMigration)
            return
        }

        defaults.set(true, forKey: Keys.hasAttemptedLegacyLicenseMigration)

        let legacyLicenseMigration = self.legacyLicenseMigration
        legacyMigrationTask?.cancel()
        legacyMigrationTask = Task.detached(priority: .utility) { [weak self] in
            let outcome = Self.performLegacyLicenseMigration(legacyLicenseMigration)
            guard !Task.isCancelled else { return }
            await self?.applyLegacyLicenseMigrationOutcome(outcome)
        }
    }

    nonisolated private static func performLegacyLicenseMigration(
        _ migration: @escaping LegacyLicenseMigration
    ) -> LegacyLicenseMigrationOutcome {
        switch migration() {
        case .success(let migratedKey):
            let normalized = migratedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                return .notFound
            }
            KeychainHelper.deleteLegacyItem(service: keychainService, account: Keys.licenseKey)
            return .migrated(normalized)
        case .notFound:
            return .notFound
        case .interactionRequired:
            return .interactionRequired
        case .failure(let status):
            return .failure(status)
        }
    }

    private func applyLegacyLicenseMigrationOutcome(_ outcome: LegacyLicenseMigrationOutcome) {
        switch outcome {
        case .migrated(let normalized):
            licenseKey = normalized
            migrateLegacyActivationStateIfNeeded()
            logger.info("Migrated legacy license key without prompting user.")
        case .interactionRequired:
            logger.info("Skipped legacy license migration: keychain interaction required.")
        case .failure(let status):
            logger.error("Failed legacy license migration read: status=\(status)")
        case .notFound:
            break
        }
    }

    #if DEBUG
    func waitForLegacyLicenseMigrationForTesting() async {
        await legacyMigrationTask?.value
    }
    #endif

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

        self.licenseKey = Self.decryptLicenseKey(
            defaults.object(forKey: Keys.licenseKey),
            migrated: defaults.bool(forKey: Keys.licenseKeyMigrated)
        ) ?? ""
        self.isLicenseActivated = false
        self.hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
        self.autoClearClipboard = defaults.object(forKey: Keys.autoClearClipboard) as? Bool ?? false
        self.autoDetectPII = defaults.object(forKey: Keys.autoDetectPII) as? Bool ?? false
        self.beautifyThemeName = defaults.string(forKey: Keys.beautifyThemeName) ?? "Clean"
        self.smartMetadataEnabled = defaults.object(forKey: Keys.smartMetadataEnabled) as? Bool ?? true
        self.semanticSearchEnabled = defaults.object(forKey: Keys.semanticSearchEnabled) as? Bool ?? true
        self.licenseEntitlement = Self.decryptLicenseEntitlement(
            defaults.object(forKey: Keys.licenseEntitlement)
        )
        self.scrollSpeed = defaults.object(forKey: Keys.scrollSpeed) as? Int ?? 300
        self.scrollMaxHeight = defaults.object(forKey: Keys.scrollMaxHeight) as? Int ?? 20_000
        self.scrollStickyHeaders = defaults.object(forKey: Keys.scrollStickyHeaders) as? Bool ?? true
        // One-time migration: scrollToTop defaulted to true in earlier builds.
        // Reset to false so captures start from the current scroll position.
        if !defaults.bool(forKey: "scrollToTopMigratedV1") {
            defaults.removeObject(forKey: Keys.scrollToTop)
            defaults.set(true, forKey: "scrollToTopMigratedV1")
        }
        self.scrollToTop = defaults.object(forKey: Keys.scrollToTop) as? Bool ?? false

        migrateLegacyLicenseSilentlyIfAvailable()
        migrateLegacyActivationStateIfNeeded()
        syncDerivedLicenseState()
        persistLicenseState()
    }
}
