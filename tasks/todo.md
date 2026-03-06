# Caloura — Production Release Plan

**Branch:** `codex/task-09-release-grade-hardening` (13,277 additions across 121 files)
**Date:** 2026-03-06
**Status:** Codex completed tasks 06-08, task 09 in progress (hit limit). This plan finishes it.

---

## Current State

| Check | Status |
|-------|--------|
| `swift build` | PASS |
| `swiftlint lint --quiet` | PASS (warnings only) |
| `swift test` (441 tests) | PASS |
| `xcodebuild build` | PASS (zero warnings) |
| `xcodebuild test` | PASS |
| `xcodebuild test` (UI tests) | PASS (5 tests) |
| `release_ready.sh --guard-only` | FAIL at `CALOURA_LICENSE_ENTITLEMENT_URL` |
| Developer ID cert | PRESENT |
| Notarization profile | PRESENT + working |
| Sparkle EdDSA key | PRESENT (appcast has signed entries) |
| caloura-site repo | PRESENT |

### Audit Summary (4 parallel deep audits completed)

- **New source files (21 files):** All clean, production-ready, no TODOs/FIXMEs. Integration complete.
- **Major refactored files (17 files):** 5 bugs found, 9 design concerns, 6 minor issues.
- **Release scripts (12 files):** 2 bugs, several portability/config issues.
- **Test suite (30+ files):** Excellent quality. ~10 timing-sensitive flaky risks, 3 global-state pollution issues.

---

## Phase 0: Merge Codex Work to Main

- [ ] **0.1** Review the full diff one more time for any missed issues
- [ ] **0.2** Merge `codex/task-09-release-grade-hardening` into `main`
- [ ] **0.3** Push to origin
- [ ] **0.4** Clean up local codex branches (`codex/task-06-*`, `codex/task-07-*`, `codex/task-08-*`, `codex/task-09-*`)

---

## Phase 1: Release-Blocking Fixes (MUST DO)

### 1.1 Version Bump

The live appcast already has v1.1.0 (build 13) and v1.2.0 (build 14). The project is
still at v1.1.0 / build 13. The next release must be at least v1.3.0 / build 15.

- [ ] **1.1a** Bump `MARKETING_VERSION` in `project.yml` to `"1.3.0"` (or chosen version)
- [ ] **1.1b** Bump `CURRENT_PROJECT_VERSION` in `project.yml` to `"15"`
- [ ] **1.1c** Run `xcodegen generate` to regenerate the Xcode project
- [ ] **1.1d** Verify `swift build` and `xcodebuild build` still pass

### 1.2 License Entitlement Backend Decision

The release script requires `CALOURA_LICENSE_ENTITLEMENT_URL` and
`CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY` in the Release config. Two paths:

**Option A — Deploy a license backend (recommended for security):**
- [ ] Build a minimal backend (e.g. Cloudflare Worker, Vercel Edge, or Lambda) that:
  - Accepts POST `{ "license_key": "..." }`
  - Validates against Gumroad API
  - Returns a signed token: `base64url(claims).base64url(Ed25519_signature)`
  - Signs with a Curve25519 private key (app has the public key)
- [ ] Generate a Curve25519 key pair
- [ ] Set `CALOURA_LICENSE_ENTITLEMENT_URL` to the backend URL in project.yml Release config
- [ ] Set `CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY` to the base64-encoded public key
- [ ] Test the full activate flow end-to-end

**Option B — Skip signed backend for now (ship faster):**
- [ ] Change `release.sh` `check_release_license_configuration` to NOT require
      the URL/key when `CALOURA_REQUIRE_SIGNED_ENTITLEMENT=NO`
- [ ] Set `CALOURA_REQUIRE_SIGNED_ENTITLEMENT: NO` in project.yml Release config
- [ ] Allow Gumroad fallback in Release builds (remove the `#if DEBUG` guard around
      `verifyWithGumroadFallback` or add a `CALOURA_ALLOW_GUMROAD_FALLBACK` build setting)
- [ ] Document this as tech debt to revisit before significant user growth

### 1.3 Fix `release_ready.sh` — `rg` Dependency

`check_log_for_warnings` uses `rg` (ripgrep) which isn't installed. Replace with `grep`.

- [ ] **1.3a** Replace `rg -n "warning:"` with `grep -n "warning:"` in `release_ready.sh`
      (lines 108, 218)
- [ ] **1.3b** Verify the script runs cleanly past the warning check

### 1.4 Fix `release.sh` — Hardcoded `/tmp` Path

Line 279 uses `/tmp/caloura-spctl.txt` instead of a `mktemp`-generated path.

- [ ] **1.4a** Replace with `mktemp` (consistent with `ZIP_VERIFY_DIR` pattern)

### 1.5 Appcast `minimumSystemVersion` for New Release

The app now requires macOS 26.0. When the new version is published, the appcast entry
must have `<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>`.

- [ ] **1.5a** Verify `caloura-site/release.sh` reads `LSMinimumSystemVersion` from the
      built app's Info.plist (or hardcodes it). If it hardcodes 14.0, fix it.
- [ ] **1.5b** Old appcast entries (1.0.0-1.2.0) should KEEP `14.0` so users on older
      macOS still see their installed version in the feed. Only the new entry gets `26.0`.
- [ ] **1.5c** Test: existing user on macOS 14 should NOT be offered the 26.0-only update

### 1.6 Fix `release.sh` — notarytool `--page-size` Flag

Line 249 uses `xcrun notarytool history --page-size 1` but the flag doesn't exist in
the current Xcode toolchain.

- [ ] **1.6a** Remove `--page-size 1` — just run `notarytool history` directly

### 1.7 Fix `project.yml` Stale Metadata

- [ ] **1.7a** Update `xcodeVersion: "15.0"` to `"26.0"` (must match Xcode for macOS 26)
- [ ] **1.7b** Update `SWIFT_VERSION: "5.9"` to `"6.0"` (Xcode 26 ships Swift 6.x,
      and `SWIFT_STRICT_CONCURRENCY: complete` implies Swift 6)

---

## Phase 2: Code Bug Fixes (SHOULD DO)

### 2.1 `isCapturing` Stuck During Permission Alert

In `CapturePipeline.swift`, the `CaptureError.noPermission` catch path calls
`await handlePermissionFailure()` while `appState.isCapturing` is still `true`.
The UI appears stuck during the alert. User cannot re-try capture while alert is up.

- [ ] **2.1a** Set `appState.isCapturing = false` before calling `handlePermissionFailure()`

### 2.2 Double OCR Enrichment on Manual Save

`CapturePipeline+Distribution.swift` `performQuickAction(.save)` calls
`addToHistoryWithOCR` even when `autoSaveToDisk` already triggered it.

- [ ] **2.2a** Guard: skip `addToHistoryWithOCR` if the screenshot already has OCR text
      or is already in the enrichment queue

### 2.3 `syncLaunchAtLoginState` Redundant Register

`CalouraApp.swift` calls `SMAppService.mainApp.register()` even when status is
already `.enabled`. Also doesn't handle `.requiresApproval` status.

- [ ] **2.3a** Only call `register()` when status is not `.enabled`
- [ ] **2.3b** Handle `.requiresApproval` explicitly (don't flip setting to false)

### 2.4 `UpdateManager.controller` is Implicitly Unwrapped Optional

`UpdateManager.swift:87` — `private var controller: (any UpdateControlling)!`
IUO is a crash risk if init path ever changes.

- [ ] **2.4a** Refactor to non-optional `let` (may require restructuring init)

### 2.5 `isAlertCooldownActive` Never Resets

`PermissionCoordinator.swift` — `updateCooldownInModel(cooldownActive: true)` is called
but `updateCooldownInModel(cooldownActive: false)` is never called. The published model
property stays `true` forever after first cooldown, even after 45s expires.

- [ ] **2.5a** Add a timer or check to reset `isAlertCooldownActive = false` after cooldown

### 2.6 URLSchemeHandler `save` Action Silently No-ops

`URLSchemeHandler.swift:70-71` — When `then=save` is passed via URL scheme but
`autoSaveToDisk` is off, the save is silently skipped with no feedback.

- [ ] **2.6a** Dispatch an explicit save command (or at minimum log a warning)

### 2.7 Two Divergent Relaunch Mechanisms

`ScreenCaptureManager+Permission.swift:145` uses `runRepairTool` + `/usr/bin/open -n`
while `relaunchApp()` at line 105 uses the `relaunchApplication` dependency.

- [ ] **2.7a** Unify to use the same relaunch mechanism for testability

### 2.8 `sckFailed` Public Var

`ScreenCaptureManager.swift:132` — `var sckFailed: Bool` has no access control.
Any module code can flip it, bypassing `handleSCKFailure` logic.

- [ ] **2.8a** Change to `private(set) var sckFailed`

---

## Phase 3: Test Stability (SHOULD DO)

### 3.1 Timing-Dependent Tests (~10 tests at risk)

Several tests use wall-clock delays that may flake under CI load:

- [ ] **3.1a** `testCancelDelayedCapture_clearsCountdownState` — increase poll timeout
      or use `XCTestExpectation` with a longer timeout
- [ ] **3.1b** `testPreviewPhase_transitionsFromPendingToComplete` — replace `Task.sleep`
      with `XCTestExpectation` or `pollUntil` with assertion on timeout failure
- [ ] **3.1c** `testRevalidation_ambiguousResponseRetriesBeforeExpiry` — increase the
      50ms expiry window to at least 500ms
- [ ] **3.1d** `testHistoryWithOCR_preservesEnrichmentForRapidCaptures` — increase the
      80ms delay differential
- [ ] **3.1e** `testRefreshState_futureRefreshSchedulesDelayedRevalidation` — same 50ms
      window issue as 3.1c
- [ ] **3.1f** `ScreenCaptureManagerPermissionTests` — replace 20ms/50ms `Task.sleep`
      with `pollUntil` or expectations
- [ ] **3.1g** `UpdateManagerTests` — replace `waitForMainQueuePropagation()` (20ms sleep)
      with proper expectation-based waiting
- [ ] **3.1h** `testPersistenceIntegrity_afterRapidAdds` — replace unconditional 1s sleep
      with debounce-aware polling

### 3.2 Global State Pollution

- [ ] **3.2a** `URLSchemeHandlerTests.testHandle_presetNormalization` — restore
      `AppSettings.shared.activePreset` in tearDown
- [ ] **3.2b** `CaptureSystemTests.testRelaunchApp_failureUpdatesStatusMessage` — restore
      `AppState.shared.statusMessage` in tearDown
- [ ] **3.2c** `URLSchemeHandler.lastHandledDate` — should be `private(set)` to prevent
      accidental external mutation beyond test setup

### 3.3 Missing Test Coverage

- [ ] **3.3a** Add isolated unit tests for `CaptureEnrichmentCoordinator` (queue ordering,
      concurrency limit, deduplication, cancellation)
- [ ] **3.3b** Add a positive-case OCR test with a known-text image fixture (even if
      assertion is loose due to Vision non-determinism)

### 3.4 `pollUntil` Ergonomics

- [ ] **3.4a** Consider making `pollUntil` fail on timeout (call `XCTFail` with a message)
      rather than silently returning — current behavior masks the real failure location

---

## Phase 4: Polish (NICE TO DO)

### 4.1 SwiftLint Warnings

- [ ] **4.1a** Split `AppSettings` into extensions to reduce type body length below 300
- [ ] **4.1b** Replace blanket `swiftlint:disable` in `ScrollCaptureEngineTests` with
      targeted `next` / `this` directives

### 4.2 Access Control Tightening

- [ ] **4.2a** Mark `CapturePipeline.overlayWindows`, `screenOverlays`,
      `areaCaptureSession`, `fullscreenCaptureSession` as `private(set)` or `internal`
- [ ] **4.2b** Mark `isSameObject` and `elapsedMilliseconds` helpers as `private`
- [ ] **4.2c** `URLSchemeHandler.lastHandledDate` — add `private(set)` or `internal`

### 4.3 UI Test Host Safety

- [ ] **4.3a** Replace `fatalError()` in `UITestHostWindowController.makePreviewImage`
      with a fallback solid-color image

### 4.4 Minor Code Cleanup

- [ ] **4.4a** `UpdateManager.finishUpdateCycle` — simplify `error.map { ... } ?? nil`
      to `error.flatMap { ... }`
- [ ] **4.4b** `ScrollCaptureEngine+Defaults.swift` — add comments for CGEvent scroll
      phase magic integers (1=began, 2=changed, 4=ended)
- [ ] **4.4c** `ScrollCaptureHelpers.swift` — add comment explaining `@unchecked Sendable`
      pointer lifetime guarantee (CFData retains the pointer)
- [ ] **4.4d** `AppSettings.scrollToTopMigratedV1` — move migration key to `Keys` enum
- [ ] **4.4e** `WindowPickerManager` — add `picker.remove(self)` in `deinit`
- [ ] **4.4f** Add `NSHumanReadableCopyright` to Info.plist

### 4.5 Project Config Cleanup

- [ ] **4.5a** Remove duplicate `MACOSX_DEPLOYMENT_TARGET` in `project.yml` (already set
      via `deploymentTarget.macOS`)
- [ ] **4.5b** `ExportOptions.plist` — align `signingStyle: automatic` with Release config
      `CODE_SIGN_STYLE: Manual` (or document why they differ)
- [ ] **4.5c** `public_download_qa.sh` — make trial simulation dates relative to `date`
      instead of hardcoded past dates

---

## Phase 5: Release Build + Publish

- [ ] **5.1** Run full `scripts/release_ready.sh` (not `--guard-only`)
- [ ] **5.2** Verify the release build archive succeeds
- [ ] **5.3** Verify notarization succeeds
- [ ] **5.4** Verify Gatekeeper + stapler validation passes
- [ ] **5.5** Run `scripts/publish.sh <version>` to publish to caloura.app
- [ ] **5.6** Verify appcast.xml has the new entry with `minimumSystemVersion=26.0`
- [ ] **5.7** Download the published zip and verify it launches on macOS 26
- [ ] **5.8** Verify Sparkle update check finds the new version
- [ ] **5.9** Upload zip to Gumroad manually
- [ ] **5.10** Tag the release commit: `git tag v<version> && git push --tags`

---

## Phase 6: Post-Release

- [ ] **6.1** Update `tasks/lessons.md` with any new findings
- [ ] **6.2** Archive completed codex task docs to `tasks/archive/`
- [ ] **6.3** If Option B was chosen for licensing, create a tracking issue for the
      signed entitlement backend

---

## Decision Log

| Decision | Options | Chosen | Rationale |
|----------|---------|--------|-----------|
| Next version | 1.3.0 / 2.0.0 | TBD | 1.3.0 if incremental; 2.0.0 if marketing the refactor |
| License backend | Option A (backend) / Option B (Gumroad fallback) | TBD | A is more secure; B ships faster |
| Merge strategy | Merge commit / Squash | TBD | Squash loses granular history; merge preserves it |

---

## Evidence (to be filled as work progresses)

| Step | Evidence | Date |
|------|----------|------|
| Phase 0 merge | | |
| Phase 1 fixes | | |
| Phase 2 fixes | | |
| Phase 3 tests | | |
| Phase 5 release | | |
