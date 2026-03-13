# Task 15: Permission + Capture Production Audit

## Objective
Audit the Screen Recording permission pipeline and the capture pipeline for correctness, resilience, user-flow smoothness, and measurable performance. Implement only clear, local P0/P1 fixes that are strongly supported by code and tests.

## Summary
- Overall severity: no P0 findings
- P1 fixes applied:
  - preserved explicit `.needsRelaunch` and `.staleRecord` diagnoses across passive refreshes for the current app identity
  - unified onboarding-state mapping so the repair window no longer shows `.completed` while Screen Recording is still only passively granted
  - removed duplicate app activation from the window-capture hot path
- Performance result: current capture release gates passed under `scripts/perf_audit.sh --strict --min-samples 5`

## Scope
- Permission flow across `PermissionCoordinator`, `ScreenCaptureManager`, onboarding revalidation, and capture-entry failure handling
- Capture flow across entrypoints, session coordinators, overlay presentation, freeze capture, execution, preview/distribution, and performance metrics
- Installed-app behavior for Screen Recording and mixed-copy edge cases
- Warm and cold capture behavior for area, fullscreen, and window capture

## Out of Scope
- Broad architecture rewrites
- New public APIs unless a narrow internal seam is insufficient
- Changes to the unrelated onboarding copy edit in `Caloura/UI/OnboardingView+Steps.swift`

## Checklist
- Establish a build/test baseline
- Re-run machine permission diagnostics on the installed app path
- Audit permission state transitions and contradictory macOS states
- Audit repair/relaunch/reset handling for stale and mixed-copy identities
- Audit capture entry, overlay, and teardown symmetry
- Audit capture-stage performance metrics and missing instrumentation
- Implement only clear P0/P1 fixes
- Re-run validation and record evidence

## Findings
### 1. Passive refresh erased explicit repair diagnoses
- Rating: P1
- Evidence:
  - `PermissionCoordinator.refreshPassiveStatus()` only considered CoreGraphics grant, the last working identity, and live validation state, so any granted current identity without a fingerprint match collapsed back to `.grantedNeedsValidation`
  - explicit `.needsRelaunch` / `.staleRecord` diagnoses were only produced in interactive validation and capture-failure paths, which meant a later passive refresh could hide the stronger diagnosis
- Expected vs actual:
  - expected: once live validation or a capture failure proves the current app copy needs relaunch or has a stale record, passive refresh should preserve that diagnosis for the same identity until a new request or working validation replaces it
  - actual: passive refresh reverted the UI to the generic “finish validation with a capture” state
- Fix applied:
  - `PermissionCoordinator` now keeps an in-memory diagnosed-failure record for the current identity and reuses it during passive refresh until a fresh permission request, denial, or working validation clears it

### 2. Permission repair entry used a divergent onboarding-state mapping
- Rating: P1
- Evidence:
  - `CalouraApp` mapped `.grantedNeedsValidation` to `.readyForFirstCapture` or `.repairStalePermissionRecord` depending on onboarding progress
  - `AppCommandController.showPermissionRepairWindow()` mapped both `.grantedNeedsValidation` and `.working` to `.completed`
- Expected vs actual:
  - expected: the repair window should use the same state mapping as launch/onboarding
  - actual: a passively granted but unvalidated permission state could render as fully completed
- Fix applied:
  - extracted shared `onboardingFlowState(for:hasCompletedOnboarding:)` logic and reused it from both launch and permission-repair entrypoints

### 3. Window capture activated the app twice
- Rating: P1
- Evidence:
  - `CapturePipeline.captureWindow()` activated the app before creating the coordinator
  - `WindowCaptureSessionCoordinator.pick()` activated the app again immediately before picker presentation and metric recording
- Expected vs actual:
  - expected: window picker activation should happen exactly once in the picker-presenting layer
  - actual: the hot path incurred duplicate AppKit activation churn and noisier picker timing
- Fix applied:
  - removed the pipeline-level activation, kept activation in `WindowCaptureSessionCoordinator`, and added a test seam to assert exactly one activation call in the coordinator path

## Fixes Applied
- Added identity-scoped diagnosed-failure preservation in `Caloura/Capture/PermissionCoordinator.swift`
- Added shared onboarding-flow mapping in `Caloura/UI/OnboardingFlowModel.swift` and reused it from `Caloura/App/CalouraApp.swift` and `Caloura/App/AppCommandController.swift`
- Removed duplicate window-capture activation from `Caloura/App/CapturePipeline+EntryPoints.swift`
- Added focused coverage in:
  - `CalouraTests/AppTests/PermissionCoordinatorTests.swift`
  - `CalouraTests/AppTests/PermissionCoordinatorEdgeCaseTests.swift`
  - `CalouraTests/AppTests/OnboardingFlowModelTests.swift`
  - `CalouraSystemTests/CaptureSystemTests.swift`

## Validation Evidence
- `swift build`
- `swiftlint lint --quiet`
- `swift test`
- `swift test --filter 'PermissionCoordinatorTests|PermissionCoordinatorEdgeCaseTests|OnboardingFlowModelTests|CaptureSystemTests'`
- `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
- `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -only-testing:CalouraSystemTests/CaptureSystemTests`
- `scripts/permission_diagnose.sh`
  - confirmed `/Applications/Caloura.app` as the installed copy
  - confirmed no remaining `DerivedData` `Caloura.app` on disk
  - showed historical `SCK permanently disabled (user declined)` events from earlier runs, which matches the prior environment issue but not a current duplicate-build state
- `scripts/perf_audit.sh --strict --min-samples 5`
  - report: `build/perf-audit/capture-perf-20260313-175659-20260313-175701.md`
  - all current gates passed for area overlay, fullscreen selector, window picker warm/cold, and preview presentation

## Notes
- Task 14 cursor hardening was committed separately as `[task-14] Harden first-frame capture cursor ownership`.
- Any task-15 commit must exclude the unrelated local edit in `Caloura/UI/OnboardingView+Steps.swift` unless the audit proves it is directly required.
