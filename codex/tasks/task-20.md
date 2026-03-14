# Task 20: Severe production audit

## Objective
Run a whole-app production audit with the recent permission/capture refactors reviewed first, then sweep the broader app for correctness, resilience, performance, and operational gaps. Fix every confirmed in-scope issue discovered during the audit.

## Context
- Depends on: `task-14` through `task-19`
- Blocking: none

## Specification
- Files to modify:
  - capture/runtime files under `Caloura/` as needed
  - focused tests under `CalouraTests/` and `CalouraSystemTests/`
  - operational scripts under `scripts/` as needed
  - `codex/CONTEXT-CHAIN.md`
  - `codex/LESSONS.md`
- Re-establish the validation baseline with:
  - `swift build`
  - `swiftlint lint --quiet`
  - `swift test`
  - `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
  - `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -only-testing:CalouraSystemTests/CaptureSystemTests`
  - `scripts/permission_diagnose.sh`
  - `scripts/perf_audit.sh --strict --min-samples 5`
- Review the permission/capture work from tasks 14-19 first, then broaden to:
  - concurrency and actor-isolation warnings
  - CoreFoundation/security bridge safety
  - AppKit/window transaction behavior
  - persistence/cache integrity
  - TCC and operational diagnostics
  - capture performance and teardown guarantees

## Acceptance Criteria
- [x] Confirmed audit findings are fixed in scope; no unresolved confirmed production-risk findings remain in this task
- [x] Focused regressions cover each confirmed code bug found during the audit
- [x] Operational diagnostics distinguish installed-app permission state from XCTest-host noise
- [x] Validation passes on the final task state

## Notes
- Do not include the unrelated local edit in `Caloura/UI/OnboardingView+Steps.swift`.
- Treat real product/runtime issues and audit-infrastructure issues separately; fix both when they are confirmed and local.

## Findings
- **[P1] Window picker presentation could still race stale same-turn picker UI.**
  - **Expected:** Back-to-back `pickWindow()` requests should cancel the earlier session before any stale picker presentation reaches AppKit.
  - **Actual:** `WindowPickerManager` presented immediately after storing the continuation, which left a small reentrancy window where a cancelled session could still present on the same main-actor turn.
  - **Evidence:** [WindowPickerManager.swift](/Users/b/Caloura/Caloura/Capture/WindowPickerManager.swift), plus new regression coverage in [WindowPickerManagerTests.swift](/Users/b/Caloura/CalouraTests/CaptureTests/WindowPickerManagerTests.swift).
- **[P1] Unreadable embedding-cache payloads did not self-heal.**
  - **Expected:** A disposable encrypted cache should discard unreadable payloads and remove the corrupted file.
  - **Actual:** `EmbeddingStore.load()` logged a startup error but left the unreadable file in place, which meant the same failure could repeat every launch.
  - **Evidence:** [EmbeddingStore.swift](/Users/b/Caloura/Caloura/Models/EmbeddingStore.swift), reproduced by [EmbeddingStoreTests.swift](/Users/b/Caloura/CalouraTests/ProcessingTests/EmbeddingStoreTests.swift).
- **[P2] Remaining type-ID-guarded CF bridges still used unsafe casts.**
  - **Expected:** Type-ID-validated CoreFoundation bridges should use a normal cast path, not `unsafeBitCast`.
  - **Actual:** `SecRequirementHandle`, `AXElementHandle`, and `AXValueHandle` still used `unsafeBitCast(...)` despite already checking the runtime type ID.
  - **Evidence:** [PermissionCoordinator.swift](/Users/b/Caloura/Caloura/Capture/PermissionCoordinator.swift) and [ScrollCaptureTypes.swift](/Users/b/Caloura/Caloura/Capture/ScrollCaptureTypes.swift).
- **[P2] Several main-actor XCTest fixtures still emitted lifecycle-isolation warnings.**
  - **Expected:** XCTest lifecycle overrides should stay nonisolated, with actor-bound setup/teardown work isolated inside the body.
  - **Actual:** A number of test fixtures still overrode `setUp()` / `tearDown()` as actor-isolated methods, which polluted the audit with avoidable concurrency warnings.
  - **Evidence:** updated fixtures in [CaptureSystemTests.swift](/Users/b/Caloura/CalouraSystemTests/CaptureSystemTests), [URLSchemeHandlerTests.swift](/Users/b/Caloura/CalouraTests/AppTests/URLSchemeHandlerTests), [ScreenCaptureManagerPermissionTests.swift](/Users/b/Caloura/CalouraTests/CaptureTests/ScreenCaptureManagerPermissionTests), and related license/clipboard/app-state/preset tests.
- **[P2] Permission diagnostics mixed installed-app state with XCTest noise.**
  - **Expected:** Operational permission diagnostics should isolate installed-app logs from test-host failure-path logs.
  - **Actual:** `scripts/permission_diagnose.sh` tailed all matching subsystem logs together, which made a healthy installed app look denied immediately after permission tests ran.
  - **Evidence:** [permission_diagnose.sh](/Users/b/Caloura/scripts/permission_diagnose.sh).

## Fixes Applied
- Updated [WindowPickerManager.swift](/Users/b/Caloura/Caloura/Capture/WindowPickerManager.swift) to schedule picker presentation across a bounded main-actor turn, cancel stale pending presentations, and generation-guard the scheduled present call.
- Added [WindowPickerManagerTests.swift](/Users/b/Caloura/CalouraTests/CaptureTests/WindowPickerManagerTests.swift) coverage proving that a second `pickWindow()` started before presentation suppresses the stale first-session present call.
- Replaced the remaining `unsafeBitCast(...)` bridges in [PermissionCoordinator.swift](/Users/b/Caloura/Caloura/Capture/PermissionCoordinator.swift) and [ScrollCaptureTypes.swift](/Users/b/Caloura/Caloura/Capture/ScrollCaptureTypes.swift) with type-safe cast paths after the existing type-ID checks.
- Changed [EmbeddingStore.swift](/Users/b/Caloura/Caloura/Models/EmbeddingStore.swift) so unreadable encrypted payloads are treated as disposable cache corruption: log at debug, clear in-memory state, and remove the corrupt file.
- Added [EmbeddingStoreTests.swift](/Users/b/Caloura/CalouraTests/ProcessingTests/EmbeddingStoreTests.swift) coverage for unreadable on-disk cache payloads.
- Converted the remaining actor-isolated XCTest lifecycle overrides to nonisolated overrides with `MainActor.assumeIsolated` for actor-bound fixture work in the touched test files.
- Updated [permission_diagnose.sh](/Users/b/Caloura/scripts/permission_diagnose.sh) to print installed-app logs and `xctest` logs in separate sections so runtime diagnosis is no longer contaminated by test-host failures.

## Validation Evidence
- `swift build`
- `swiftlint lint --quiet`
- `swift test`
- `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
- `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -only-testing:CalouraSystemTests/CaptureSystemTests`
- `scripts/permission_diagnose.sh`
- `scripts/perf_audit.sh --strict --min-samples 5`
- Strict perf evidence: [capture-perf-20260314-132525-20260314-132526.md](/Users/b/Caloura/build/perf-audit/capture-perf-20260314-132525-20260314-132526.md)

## Residual Risks
- `scripts/perf_audit.sh` reads unified logs, so it should be run after the capture workload exits and its metrics are visible in `log show`; otherwise a premature run can report temporary missing-data failures even when the capture path is healthy.
- The `xctest` permission denials shown in the diagnostics are expected from failure-path tests and are no longer treated as installed-app evidence.
- No unresolved confirmed in-scope production-risk findings remain after this audit pass.
