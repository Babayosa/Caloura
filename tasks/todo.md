# Task 13 — Follow-Up Audit (5 Streams)

Date: 2026-02-05
Owner: Caloura Engineering
Status: Complete

## Audit Streams (All Complete)

### Stream 1: Dead Code — 27 findings (5 High, 9 Med, 12 Low, 1 Info)
### Stream 2: Security — 26 findings (3 High, 5 Med, 6 Low, 12 Info)
### Stream 3: Architecture — 9 findings (0 High, 2 Med, 3 Low, 4 Info)
### Stream 4: Test Coverage — 18 findings (3 P0, 3 P1, 7 P2, 5 P3)
### Stream 5: Build Hygiene — 20 findings (2 High, 2 Med, 3 Low, 13 Info)

## Consolidated Findings — Prioritized Fix List

### HIGH (fix now)

#### Dead Code Removal (S1)
- [x] S1-01: Remove `ProcessedScreenshot.releaseEncodedData()` (never called)
- [x] S1-02: Remove `ProcessedScreenshot.cachePNGData(_:)` / `cacheTIFFData(_:)` (never called)
- [x] S1-03: Remove `FileOrganizer.saveSync(...)` (all callers use async)
- [x] S1-05/06: Remove dead `captureWindow(scWindow:)` and `captureWindow(_ window:)` overloads
- [x] S1-11..15: Remove dead `getWindows()` cluster (getWindows, sckGetWindows, getWindowsCG, zOrderedWindowIDs, cachedIcon) ~120 LOC

#### Security Fixes (S2)
- [x] S2-16: License bypass — empty licenseKey + isLicenseActivated=true skips revalidation
- [x] S2-15: Trial clock rollback — store monotonic "furthest date seen"

#### Build Hardening (S5)
- [x] S5-2: Align project.yml Sparkle pin to `exactVersion: "2.8.1"` (currently `from: "2.5.0"`)
- [x] S5-6: Add `SWIFT_STRICT_CONCURRENCY: complete` to project.yml

#### Architecture Bug (S3)
- [x] S3-2: AnnotationWindowController missing `isReleasedWhenClosed = false` (use-after-free)

### MEDIUM (fix in second pass)

#### Dead Code (S1)
- [x] S1-04/09: Remove dead `showPermissionAlert()` 0-arg + `diagnosePermissionState()`
- [x] S1-07: Remove `CaptureMode.displayName`, `.systemImage`, `CaseIterable`
- [x] S1-10: Remove `PinnedScreenshotManager.unpinAll()` (never called)
- [x] S1-16: Remove `AppSettings.saveDirectoryURL` (never read)
- [x] S1-17: Remove dead `Notification.Name.showSetupGuide` (declared+observed, never posted)
- [x] S1-21: Remove `OnboardingPermissionPresentation.showsQuitButton` (set but never read in UI)

#### Security (S2)
- [x] S2-6: ~~`saveSync` creates directories before path validation~~ — moot, `saveSync` removed in S1-03
- [x] S2-3: URL scheme rate limiting — add timestamp-based throttle
- [x] S2-10: Temp file TOCTOU — create file with 0600 before passing to screencapture
- [x] S2-17: Spoofable revalidation date — reject future `lastLicenseValidationDate`

#### Build (S5)
- [x] S5-7: Add `ENABLE_USER_SCRIPT_SANDBOXING: YES` to project.yml
- [x] S5-3: Narrow KeyboardShortcuts pin from `from: "2.0.0"` to `from: "2.4.0"`

#### Architecture (S3)
- [x] S3-9: HistoryWindowController missing `NSApp.activate()` in bring-to-front path

### LOW / INFO (document, fix opportunistically)

- S1-08: ContextDetector.categorize() — test-only, keep for test coverage
- S1-18: KeychainHelper — migration-only, keep until all users migrated
- S1-19: 11 redundant `import Foundation` statements
- S1-20: OCREngine imports AppKit unnecessarily
- S1-22..26: Unused Codable conformances, CaseIterable, error cases
- S2-4/7/11/13/19/22: URL scheme source validation, preset subfolder sanitization, temp file startup cleanup, clipboard auto-clear, crypto threat model docs, sandbox disabled
- S3-1: Window controller boilerplate (~140 LOC savings with generic)
- S3-4/6/7/8: CaptureBackend protocol, singleton injection, notification round-trips, pipeline responsibility
- S4-01..18: Test coverage gaps (separate task)
- S5-8/15/20: DEAD_CODE_STRIPPING, Swift 5 language lock

## Verification
- [x] `xcodebuild build` passes
- [x] `swift test` passes — 149 tests, 0 failures (+1 new test for S2-16 license bypass)
- [x] `swiftlint lint --quiet` clean
- [x] Update tasks/lessons.md with any new lessons

## Review / Evidence

### Build & Test Output (2026-02-05)
```
swift test: Executed 149 tests, with 0 failures (0 unexpected) in 1.587s
swiftlint lint --quiet: (no output — clean)
```

### Changes Summary
**HIGH fixes (10 items):**
- Dead code: ~215 LOC removed across ProcessedScreenshot, FileOrganizer, ScreenCaptureManager + 2 extensions
- Security: License bypass (S2-16), trial clock rollback (S2-15), revalidation date spoofing (S2-17)
- Build: Sparkle exact pin (S5-2), SWIFT_STRICT_CONCURRENCY complete (S5-6)
- Architecture: AnnotationWindowController isReleasedWhenClosed (S3-2)

**MEDIUM fixes (13 items):**
- Dead code: 6 removals (showPermissionAlert 0-arg, diagnosePermissionState, CaptureMode extras, unpinAll, saveDirectoryURL, showSetupGuide, showsQuitButton)
- Security: URL scheme rate limiting (S2-3), temp file TOCTOU 0600 (S2-10), saveSync moot (S2-6)
- Build: ENABLE_USER_SCRIPT_SANDBOXING (S5-7), KeyboardShortcuts pin narrowed (S5-3)
- Architecture: HistoryWindowController NSApp.activate() in bring-to-front path (S3-9)

**Test changes:**
- Fixed testActivationState_licensed to provide license key (was relying on empty key + activated)
- Added testActivationState_licensed_emptyKeyRevokes (validates S2-16 fix)
- Added setUp to URLSchemeHandlerTests to reset throttle state (for S2-3 compatibility)
