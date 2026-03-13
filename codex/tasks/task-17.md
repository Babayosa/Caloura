# Task 17: Permission Core Split

## Objective
Extract the pure Screen Recording rule engine out of `PermissionCoordinator` so status derivation and permission messaging live in a smaller internal unit while the coordinator remains responsible for side effects, persistence, and repair actions.

## Context
- Depends on: `task-16`
- Blocking: none

## Specification
- Files to modify:
  - `Caloura/Capture/PermissionCoordinator.swift`
  - `Caloura/Capture/` permission-related support files as needed
  - focused permission tests under `CalouraTests/AppTests/`
  - `Caloura.xcodeproj/project.pbxproj` if new source files are added
  - `codex/CONTEXT-CHAIN.md`
  - `codex/LESSONS.md`
- Create a small internal permission-core type that owns:
  - passive status resolution
  - explicit failure classification (`needsRelaunch` vs `staleRecord`)
  - permission guidance / non-blocking messaging
  - stale-record banner derivation and `PermissionUIModel` construction inputs
- Keep `PermissionCoordinator` responsible for:
  - live validation and repair orchestration
  - persistence of historical working identity
  - cooldown state
  - publishing and side effects
- Add focused regression coverage proving:
  - passive status rules remain unchanged
  - explicit failure classification remains unchanged
  - fresh permission requests still clear explicit diagnoses
  - message/model rendering for stale-record and validation-needed states still matches current behavior

## Acceptance Criteria
- [x] `PermissionCoordinator` delegates pure status/messaging rules to a smaller internal unit
- [x] Focused permission tests cover the extracted rule engine directly
- [x] All validation passes (`swift build`, `swiftlint lint --quiet`, `swift test`)

## Notes
- Do not include the unrelated local edit in `Caloura/UI/OnboardingView+Steps.swift`.
- Keep the task scoped to the permission pipeline; do not broaden into onboarding flow or capture-pipeline refactors here.

## Findings
- `PermissionCoordinator` still owned too much pure logic after task 16. The side-effect flow was centralized, but passive status derivation, explicit failure classification, and permission messaging were still embedded in the coordinator.
- That structure made the coordinator harder to reason about and left the permission rules mostly testable only through the full coordinator orchestration path.

## Fixes Applied
- Added [PermissionStatusCore.swift](/Users/b/Caloura/Caloura/Capture/PermissionStatusCore.swift) with a compact `PermissionStatusContext` plus pure helpers for:
  - passive status resolution
  - explicit failure classification
  - UI model rendering
  - non-blocking permission messages
- Updated [PermissionCoordinator.swift](/Users/b/Caloura/Caloura/Capture/PermissionCoordinator.swift) so it builds a status context from live coordinator state, then delegates rule evaluation and UI rendering to `PermissionStatusCore` while still owning persistence, repair orchestration, and status publication side effects.
- Added [PermissionStatusCoreTests.swift](/Users/b/Caloura/CalouraTests/AppTests/PermissionStatusCoreTests.swift) to cover the extracted rule engine directly, while keeping the existing coordinator regression coverage intact.
- Regenerated [project.pbxproj](/Users/b/Caloura/Caloura.xcodeproj/project.pbxproj) so the new source and test files are present in Xcode builds.

## Validation Evidence
- `xcodegen generate`
- `swift build`
- `swiftlint lint --quiet`
- `swift test`
- `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
