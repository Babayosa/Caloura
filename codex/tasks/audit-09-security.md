# Audit Task 09: Security Audit

## Scope

- `Caloura/Security/HistoryCrypto.swift`
- `Caloura/Security/KeychainHelper.swift`
- `Caloura/App/LicenseManager.swift`
- `Caloura/App/LicenseManager+Shared.swift`
- `Caloura/Processing/PIIDetector.swift`
- `Caloura/Resources/Caloura.entitlements`
- `project.yml`

## Summary

- No Critical findings.
- One High-severity finding exists in the licensing path: local mutable defaults can still mint or reset time-bounded license state without a successful signed entitlement round-trip.
- The at-rest crypto implementation is generally sound: AES-256-GCM, purpose-separated HKDF derivation, keychain-backed root key storage, and restrictive `0600` / `0700` file permissions are all in place.
- PII detection is privacy-conscious in storage terms, but coverage is intentionally narrow and will miss common secret/token formats.
- The app is intentionally unsandboxed while hardened runtime is enabled; no extra hardened-runtime exception entitlements were found.

## Ratings

| Area | Rating | Why |
| --- | --- | --- |
| Crypto | Low | Correct primitive choice, key separation, fresh nonces via CryptoKit, and restrictive file permissions. Main gap is forward-compat/error signaling, not a live confidentiality break. |
| License | High | Legacy migration and trial state still trust mutable `UserDefaults` enough to reconstruct licensed/trial access locally. |
| PII | Medium | Detection coverage is limited to six regex families plus top-candidate OCR, so false negatives are likely for real-world secrets. |
| Entitlements | Medium | The app is unsandboxed, which materially expands local attack surface for a screen-recording/accessibility tool, even though hardened runtime is on and no extra exceptions are present. |
| Build config | Low | Release is wired for signed entitlement verification, and no repo-local signing path uses the configured license key as a private key. The checked-in value still needs out-of-band provenance confirmation. |

## High-Severity Findings

### 1. Legacy activation migration can mint a local “licensed” entitlement from mutable defaults

- Severity: High
- Evidence:
  - `AppSettings.persistLicenseState()` still mirrors `isLicenseActivated` into `UserDefaults` for compatibility (`Caloura/Models/AppSettings.swift:241-266`).
  - `decryptLicenseKey(...)` still accepts legacy plaintext `licenseKey` values whenever `licenseKeyMigrated` is false (`Caloura/Models/AppSettings.swift:280-300`).
  - `migrateLegacyActivationStateIfNeeded()` creates a fresh 7-day `LicenseEntitlement` when `licenseEntitlement == nil`, `defaults.bool(forKey: isLicenseActivated)` is true, and `licenseKey` is non-empty (`Caloura/Models/AppSettings.swift:320-346`).
- Impact:
  - A local user who can edit the app’s defaults can reconstruct a time-bounded “licensed” state without a valid signed entitlement.
  - This does not require successful backend verification and survives startup because the synthesized entitlement is then persisted in encrypted form.
- Recommendation:
  - Remove the `isLicenseActivated`-based reconstruction path entirely, or gate it behind positive proof that a real legacy keychain migration just occurred in the same launch.
  - Concretely: only allow legacy entitlement reconstruction from `performLegacyLicenseMigration(...) == .migrated(...)`; do not trust the mirrored `UserDefaults` boolean on its own.

### 2. Trial anti-rollback only defends against clock rewind inside one defaults store

- Severity: High
- Evidence:
  - Trial remaining time is derived from `firstLaunchDate` plus `furthestDateSeen` (`Caloura/App/LicenseManager.swift:143-155`).
  - Both values are stored in mutable `UserDefaults` (`Caloura/Models/AppSettings.swift:162-164`, `Caloura/Models/AppSettings.swift:442-449`).
- Impact:
  - Rolling the clock backward within the same defaults store is handled, but deleting defaults, resetting the app container, or reinstalling the app resets the trial anchor.
  - This makes the trial easy to extend indefinitely without touching the signed-entitlement path.
- Recommendation:
  - Store the trial anchor in a tamper-resistant location such as a device-local keychain item, or move trial issuance/refresh to the signed entitlement backend.
  - If product policy allows only local enforcement, keychain-backed first-seen state is the minimum hardening step.

## Detailed Assessment

### Crypto

- Rating: Low
- Strengths:
  - History data is encrypted with AES-GCM using a 256-bit key (`Caloura/Security/HistoryCrypto.swift:51-58`).
  - Purpose-specific subkeys are derived through HKDF with explicit `purpose` strings (`Caloura/Security/HistoryCrypto.swift:88-95`).
  - The root key is keychain-backed in normal runtime, and the keychain item is written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`Caloura/Security/HistoryCrypto.swift:117-156`, `Caloura/Security/KeychainHelper.swift:59-89`).
  - Encrypted payload files are written under `0700` directories and forced to `0600` afterwards (`Caloura/Security/HistoryCrypto.swift:220-236`).
- Notes:
  - `AES.GCM.seal(data, using: derivedKey)` does not supply a caller-managed nonce, so nonce generation is delegated to CryptoKit. That is the correct usage pattern here.
  - The format has a single-byte version prefix (`currentKeyVersion = 1`) and can still read pre-version/pre-HKDF legacy blobs (`Caloura/Security/HistoryCrypto.swift:47-85`).
- Residual risk:
  - Unknown future versions are not distinguished cleanly from corruption or legacy-format failure. That is a maintainability / migration issue, not an active break.

### License

- Rating: High
- Strengths:
  - Release configuration requires signed entitlement verification and disables Gumroad fallback (`project.yml:54-59`, `Caloura/App/LicenseManager.swift:339-367`).
  - Signed entitlements are verified with `Curve25519.Signing.PublicKey` before activation, and the claims are checked for product ID and time ordering (`Caloura/App/LicenseManager.swift:494-527`).
  - Persisted license keys and entitlement artifacts are encrypted through `HistoryCrypto` under separate purposes (`Caloura/Models/AppSettings.swift:270-308`).
  - Revalidation scheduling respects `refreshAfter` / `expiresAt` and retries ambiguous/network failures without silently granting permanent access (`Caloura/App/LicenseManager.swift:229-337`).
- Findings:
  - The two High-severity findings above make local trial/licensed-state abuse too easy for a production release.
- Additional note:
  - `LicenseManager+Shared.swift` is only a convenience singleton wrapper; the actual security properties come from `LicenseManager` plus `AppSettings`, not the `.shared` surface (`Caloura/App/LicenseManager+Shared.swift:3-23`).

### PII

- Rating: Medium
- Coverage assessment:
  - The detector only looks for `email`, `phone`, `creditCard`, `apiKey`, `ipAddress`, and `ssn` (`Caloura/Processing/PIIDetector.swift:5-36`).
  - OCR uses only the top recognized candidate per text region (`Caloura/Processing/PIIDetector.swift:125-141`), which reduces noise but increases false negatives on ambiguous captures.
  - Validation is strong for cards, IPs, and SSNs (`Caloura/Processing/PIIDetector.swift:165-210`), but the token/API-key regex is intentionally broad and still misses structured credentials such as JWTs, cloud access keys with separators, and many region-specific identifiers.
- Persistence assessment:
  - PII detection results themselves are in-memory only (`Caloura/Models/AppState.swift:67-78`).
  - Persisted history encodes `recentScreenshots` only (`Caloura/Models/AppState.swift:247-272`), and those `ScreenshotItem` records carry OCR text, summary, and auto-tags (`Caloura/Models/ScreenshotItem.swift:3-120`).
  - Because history persistence goes through `HistoryCrypto`, those stored metadata fields are encrypted at rest, but the original screenshot artifact is separate from this audit path.
- Recommendation:
  - Document the supported PII classes explicitly in product/security docs and expand the pattern set if the product promise is broader than “basic sensitive-info detection.”

### Entitlements

- Rating: Medium
- Evidence:
  - The app explicitly opts out of App Sandbox (`Caloura/Resources/Caloura.entitlements:4-6`).
  - Hardened runtime is enabled in the build config (`project.yml:43-45`).
  - No additional hardened runtime exception entitlements were found in the checked-in entitlements file.
- Assessment:
  - For a direct-distribution screenshot tool, unsandboxed operation may be intentional, especially given screen recording and accessibility-driven automation.
  - The tradeoff is a larger blast radius if the app process is compromised: broader file-system, network, and process interaction surfaces remain available than in a sandboxed app.
- Recommendation:
  - Keep the unsandboxed posture documented as an intentional product decision and continue reviewing all user-controlled file/network/process boundaries as if the app were a privileged local client.

### Build Config

- Rating: Low
- Evidence:
  - Release builds embed a configured signed-entitlement URL and a value named `CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY` (`project.yml:54-59`).
  - The code only consumes that value as `Curve25519.Signing.PublicKey(rawRepresentation:)` (`Caloura/App/LicenseManager.swift:504-510`).
- Verification result:
  - The configured base64 value decodes to 32 bytes.
  - Local static inspection does **not** conclusively prove “public, not private” because CryptoKit also accepts the same 32-byte blob as a private-key seed type.
  - I did **not** find any repo-local signing path or private-key use of this configured value, so there is no direct evidence of a checked-in signing secret in this repository.
- Recommendation:
  - Treat provenance as an operational check: confirm the release config value matches the backend signer’s published public key out of band (for example, from secret-management or deployment records), not just by code inspection.

## Overall Recommendation

- Release decision from a security standpoint: do not treat licensing as production-hardened until the two High findings are fixed.
- Everything else in this audit is compatible with release if the product accepts the current unsandboxed posture and the intentionally limited PII-detection scope.
