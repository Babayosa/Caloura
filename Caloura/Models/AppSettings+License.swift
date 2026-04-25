import Foundation
import os.log

// License subsystem split out of AppSettings.swift to keep the main type
// body under SwiftLint's `type_body_length` threshold. Stored properties
// (@Published licenseKey, isLicenseActivated, licenseEntitlement,
// licenseReady, legacyMigrationTask, legacyLicenseMigration) must stay on
// the main type because Swift does not allow stored state in extensions.
extension AppSettings {

    enum LegacyLicenseMigrationOutcome: Sendable {
        case notFound
        case migrated(String)
        case interactionRequired
        case failure(OSStatus)
    }

    // MARK: - Exposed helpers

    var currentLicenseEntitlement: LicenseEntitlement? {
        licenseEntitlement
    }

    var lastLicenseValidationDate: Date? {
        get { defaults.object(forKey: Keys.lastLicenseValidationDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastLicenseValidationDate) }
    }

    func updateLicenseEntitlement(_ entitlement: LicenseEntitlement?) {
        licenseEntitlement = entitlement
        lastLicenseValidationDate = entitlement?.validatedAt
    }

    func syncDerivedLicenseState(referenceDate: Date = Date()) {
        isLicenseActivated = licenseEntitlement?.isCurrentlyValid(at: referenceDate) ?? false
    }

    func licenseStatePersistenceMatchesMemory() -> Bool {
        let normalized = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedKey = Self.decryptLicenseKey(
            defaults.object(forKey: Keys.licenseKey),
            migrated: defaults.bool(forKey: Keys.licenseKeyMigrated),
            migrationLocked: defaults.bool(forKey: Keys.licenseKeyMigrationLocked)
        ) ?? ""
        guard persistedKey == normalized else { return false }

        let persistedEntitlement = Self.decryptLicenseEntitlement(
            defaults.object(forKey: Keys.licenseEntitlement)
        )
        return persistedEntitlement == licenseEntitlement
    }

    // MARK: - Persistence

    func persistLicenseState() {
        let normalized = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            defaults.removeObject(forKey: Keys.licenseKey)
        } else {
            if let encrypted = Self.encryptLicenseKey(normalized) {
                defaults.set(encrypted, forKey: Keys.licenseKey)
                defaults.set(true, forKey: Keys.licenseKeyMigrated)
                // Lock plaintext acceptance permanently after the first
                // encrypted persist. Defense against UserDefaults tampering
                // that flips `licenseKeyMigrated` back to false to inject
                // a forged plaintext key.
                defaults.set(true, forKey: Keys.licenseKeyMigrationLocked)
            } else {
                licenseLogger.error("Failed to encrypt license key — not persisting")
            }
        }

        if let licenseEntitlement {
            if let encryptedEntitlement = Self.encryptLicenseEntitlement(licenseEntitlement) {
                defaults.set(encryptedEntitlement, forKey: Keys.licenseEntitlement)
            } else {
                licenseLogger.error("Failed to encrypt license entitlement — not persisting")
            }
        } else {
            defaults.removeObject(forKey: Keys.licenseEntitlement)
        }

        // Mirror the derived state for compatibility, but do not trust this value on load.
        defaults.set(isLicenseActivated, forKey: Keys.isLicenseActivated)
    }

    // MARK: - Encryption / Decryption

    nonisolated static func encryptLicenseKey(_ plaintext: String) -> Data? {
        guard let data = plaintext.data(using: .utf8) else { return nil }
        return try? HistoryCrypto.encrypt(data, purpose: "license-key")
    }

    nonisolated static func encryptLicenseEntitlement(_ entitlement: LicenseEntitlement) -> Data? {
        guard let data = try? JSONEncoder().encode(entitlement) else { return nil }
        return try? HistoryCrypto.encrypt(data, purpose: "license-artifact")
    }

    nonisolated static func decryptLicenseKey(
        _ stored: Any?,
        migrated: Bool,
        migrationLocked: Bool
    ) -> String? {
        if let data = stored as? Data {
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
        if migrationLocked {
            // Plaintext after the lock is either UserDefaults tampering or
            // a downgrade attack. Treat as no license rather than trusting
            // unauthenticated input.
            licenseLogger.error("license_decrypt_rejected_plaintext reason=migration_locked")
            return nil
        }
        if migrated { return nil }
        return stored as? String
    }

    nonisolated static func decryptLicenseEntitlement(_ stored: Any?) -> LicenseEntitlement? {
        guard let data = stored as? Data,
              let decrypted = try? HistoryCrypto.decrypt(data, purpose: "license-artifact") else {
            return nil
        }
        return try? JSONDecoder().decode(LicenseEntitlement.self, from: decrypted)
    }

    // MARK: - Legacy activation bridging

    func migrateLegacyActivationStateIfNeeded(legacyActivatedFlag: Bool? = nil) {
        let activatedFlag = legacyActivatedFlag ?? defaults.bool(forKey: Keys.isLicenseActivated)
        guard licenseEntitlement == nil, activatedFlag else {
            return
        }

        let normalized = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        licenseLogger.info(
            "legacy_activation_ignored reason=unverified_defaults"
        )
        syncDerivedLicenseState()
    }

    // MARK: - Legacy keychain migration

    /// Best-effort migration path for legacy keychain-backed license keys.
    /// Non-interactive, runs off-main, never shows authentication UI.
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

    nonisolated static func performLegacyLicenseMigration(
        _ migration: @escaping LegacyLicenseMigration
    ) -> LegacyLicenseMigrationOutcome {
        switch migration() {
        case .success(let migratedKey):
            let normalized = migratedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                return .notFound
            }
            KeychainHelper.deleteLegacyItem(
                service: keychainService,
                account: Keys.licenseKey
            )
            return .migrated(normalized)
        case .notFound:
            return .notFound
        case .interactionRequired:
            return .interactionRequired
        case .failure(let status):
            return .failure(status)
        }
    }

    func applyLegacyLicenseMigrationOutcome(_ outcome: LegacyLicenseMigrationOutcome) {
        switch outcome {
        case .migrated(let normalized):
            licenseKey = normalized
            migrateLegacyActivationStateIfNeeded()
            licenseLogger.info("Migrated legacy license key without prompting user.")
        case .interactionRequired:
            licenseLogger.info("Skipped legacy license migration: keychain interaction required.")
        case .failure(let status):
            licenseLogger.error("Failed legacy license migration read: status=\(status)")
        case .notFound:
            break
        }
    }

    #if DEBUG
    func waitForLegacyLicenseMigrationForTesting() async {
        await licenseReady?.value
        await legacyMigrationTask?.value
    }
    #endif

    // MARK: - Default migration provider

    nonisolated static func defaultLegacyLicenseMigration() -> LegacyKeychainReadResult {
        KeychainHelper.readLegacyStringNonInteractive(
            service: keychainService,
            account: Keys.licenseKey
        )
    }

    // MARK: - Activation

    /// Decrypts persisted license state off the launch thread. Writes results
    /// back on MainActor, then fires silent legacy-keychain migration.
    /// Exposes `licenseReady` for callers that need to block on settled state.
    func activateLicenseSubsystem() {
        let keyBlob = defaults.object(forKey: Keys.licenseKey)
        let entitlementBlob = defaults.object(forKey: Keys.licenseEntitlement)
        let alreadyMigrated = defaults.bool(forKey: Keys.licenseKeyMigrated)
        let migrationLocked = defaults.bool(forKey: Keys.licenseKeyMigrationLocked)
        // Capture the legacy activation flag before any mutation — setting
        // licenseKey in the MainActor hop cascades into persistLicenseState,
        // which writes the in-memory (false) `isLicenseActivated` back to
        // defaults. The legacy migration checker needs the pre-mutation value.
        let legacyActivated = defaults.bool(forKey: Keys.isLicenseActivated)
        // Nothing persisted? Skip the async round trip — still run migrations
        // synchronously so legacy keychain reads still schedule. Skipping the
        // Task also avoids a stale-decrypt race where a test or caller writes
        // to `licenseKey` before the Task's MainActor hop runs.
        if keyBlob == nil, entitlementBlob == nil, !legacyActivated {
            // Fresh install (or post-reset): nothing to migrate, so lock
            // plaintext acceptance immediately. Any future plaintext value
            // appearing in UserDefaults is necessarily injected.
            defaults.set(true, forKey: Keys.licenseKeyMigrationLocked)
            migrateLegacyLicenseSilentlyIfAvailable()
            syncDerivedLicenseState()
            persistLicenseState()
            return
        }

        licenseReady = Task { [weak self] in
            let decryptedKey = Self.decryptLicenseKey(
                keyBlob,
                migrated: alreadyMigrated,
                migrationLocked: migrationLocked
            ) ?? ""
            let decryptedEntitlement = Self.decryptLicenseEntitlement(entitlementBlob)
            await MainActor.run {
                guard let self else { return }
                // Only populate if the property is still at its init default.
                // Callers (tests, LicenseManager.activate) may have written
                // concrete values between init and this hop.
                if self.licenseKey.isEmpty, !decryptedKey.isEmpty {
                    self.licenseKey = decryptedKey
                }
                if self.licenseEntitlement == nil, let decryptedEntitlement {
                    self.licenseEntitlement = decryptedEntitlement
                }
                self.migrateLegacyLicenseSilentlyIfAvailable()
                self.migrateLegacyActivationStateIfNeeded(
                    legacyActivatedFlag: legacyActivated
                )
                self.syncDerivedLicenseState()
                // Do not call persistLicenseState() here. The didSets on
                // licenseKey / licenseEntitlement already persisted any
                // writes. Calling persistLicenseState with an empty
                // licenseKey would wipe the persisted blob on decrypt
                // failure (a recoverable state becomes permanent loss).
                // isLicenseActivated is a mirror — keep it in sync without
                // touching encrypted blobs.
                self.defaults.set(
                    self.isLicenseActivated,
                    forKey: Keys.isLicenseActivated
                )
            }
        }
    }
}

private let licenseLogger = Logger(subsystem: "com.caloura.app", category: "AppSettings.License")
