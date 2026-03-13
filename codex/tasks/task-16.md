# Task 16: Permission State Core Normalization

## Objective
Centralize Screen Recording status derivation and transition side effects inside `PermissionCoordinator` so passive refresh, live validation, repair, and capture-failure handling all use the same rules.

## Context
- Depends on: `task-15`
- Blocking: none

## Specification
- Files to modify:
  - `Caloura/Capture/PermissionCoordinator.swift`
  - focused permission tests under `CalouraTests/AppTests/`
  - `codex/CONTEXT-CHAIN.md`
  - `codex/LESSONS.md`
- Create a narrow internal status-resolution path that:
  - computes passive Screen Recording state from one context model instead of ad hoc switch logic
  - centralizes working / denied / explicit-failure transition side effects
  - keeps guidance and non-blocking messaging aligned with the same status context
- Preserve current external behavior where it is already correct:
  - passive mismatch alone must remain advisory
  - explicit `.needsRelaunch` / `.staleRecord` diagnoses must remain sticky for the current identity
  - fresh permission requests must clear explicit repair diagnoses
- Add regression coverage for:
  - explicit diagnosis clearing on a fresh permission request
  - consistent passive-state recovery after working validation
  - any new helper path that replaces duplicated transition logic

## Acceptance Criteria
- [x] `PermissionCoordinator` uses shared internal helpers for passive status resolution and terminal transitions
- [x] Focused permission tests cover the new shared paths and diagnosis-clearing behavior
- [x] All validation passes (`swift build`, `swiftlint lint --quiet`, `swift test`)

## Notes
- Do not include the unrelated local edit in `Caloura/UI/OnboardingView+Steps.swift`.
- Keep this task internal to the permission flow; do not broaden into onboarding or capture architecture changes unless required for the normalization.

## Findings
- Duplicated status publication logic across passive refresh, interactive validation, settings-return revalidation, and capture-failure repair had started to diverge. The behavior was correct in the important cases, but the coordinator was maintaining working / denied / explicit-failure side effects in too many places.
- A fresh permission request needed an explicit regression test so a previously diagnosed `.needsRelaunch` state could cleanly fall back to `.grantedNeedsValidation` while the app waits for the next live validation.
- Full-suite validation surfaced a separate flaky test in `CaptureEnrichmentCoordinatorTests`: with two worker slots, the first two jobs may start in either order, so the test was asserting scheduler luck instead of the coordinator’s real contract.

## Fixes Applied
- Added shared internal helper paths in `PermissionCoordinator`:
  - `passiveStatus(for:at:cgGranted:)`
  - `publishPassiveStatus(for:at:cgGranted:)`
  - `publishWorkingValidated(_:)`
  - `publishDenied(_:)`
  - `publishExplicitFailure(for:)`
  - `publishStatus(_:identity:)`
- Rewired `refreshPassiveStatus()`, `primeIfPermissionGranted()`, `runUserInitiatedValidation()`, `revalidateAfterSettingsReturn()`, and `handleCapturePermissionFailure()` to use the shared transition helpers instead of repeating side-effect logic inline.
- Added `PermissionCoordinatorCoreNormalizationTests` with regression coverage proving that `requestPermissionFromSystem()` clears an explicit repair diagnosis and returns the coordinator to `.grantedNeedsValidation` until live validation succeeds again.
- Tightened `CaptureEnrichmentCoordinatorTests.testFinish_startsNextPendingOperationWhenASlotOpens` so it asserts causal ordering around the freed worker slot instead of requiring a fabricated start order between the first two concurrently allowed jobs.
- Regenerated `Caloura.xcodeproj` so the new focused permission test is present in Xcode builds.

## Validation Evidence
- `xcodegen generate`
- `swift build`
- `swiftlint lint --quiet`
- `swift test`
