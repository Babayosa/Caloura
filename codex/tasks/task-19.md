# Task 19: Capture entrypoint hardening

## Objective
Extract capture entry/session orchestration out of `CapturePipeline` so area, fullscreen, window, repeat, and delayed capture startup/teardown share one internal lifecycle path with explicit session-state ownership.

## Context
- Depends on: `task-18`
- Blocking: none

## Specification
- Files to modify:
  - `Caloura/App/CapturePipeline.swift`
  - `Caloura/App/CapturePipeline+EntryPoints.swift`
  - `Caloura/App/CapturePipeline+ScrollCapture.swift`
  - `Caloura/App/` capture-related support files as needed
  - focused capture tests under `CalouraTests/AppTests/`
  - `Caloura.xcodeproj/project.pbxproj` if new source files are added
  - `codex/CONTEXT-CHAIN.md`
  - `codex/LESSONS.md`
- Extract a narrow internal entrypoint service that owns:
  - capture mode dispatch for area, fullscreen, window, repeat, and delayed capture
  - hot-path startup timing and first-visible-overlay metrics
  - shared interrupted-capture teardown
  - stale callback guarding for overlay/frozen-image async work
- Move capture-session mutable state into a dedicated internal container rather than leaving the new service coupled to ad hoc `CapturePipeline` properties.
- Keep `CapturePipeline` responsible for:
  - public façade methods used by commands/UI
  - injected dependencies and factory seams
  - post-capture execution delegation
  - scroll capture execution flow
- Preserve the current UX and performance behavior:
  - area capture still presents overlays immediately and applies frozen snapshots later
  - fullscreen multi-display selection still cleans up symmetrically on select/cancel
  - delayed capture still clears countdown UI and does not leave stale task references
- Add focused tests proving:
  - stale frozen-image completion cannot update a cancelled area session
  - fullscreen multi-display cancel clears capture state
  - delayed capture completion clears the stored countdown task reference

## Acceptance Criteria
- [x] `CapturePipeline` delegates entry/session orchestration to a dedicated internal service
- [x] Shared hot-path mutable state lives in an internal capture-session state container
- [x] Focused lifecycle tests cover stale async updates, fullscreen cancellation symmetry, and delayed-task cleanup
- [x] All validation passes (`swift build`, `swiftlint lint --quiet`, `swift test`)

## Notes
- Do not include the unrelated local edit in `Caloura/UI/OnboardingView+Steps.swift`.
- Keep the task scoped to entrypoint/session lifecycle hardening; do not broaden into permission or post-capture redesign work here.

## Findings
- After task 18, `CapturePipeline` still mixed façade methods with hot-path entry orchestration, delayed countdown dispatch, multi-display session setup, and stale-callback guards.
- The hot-path mutable state for overlays, fullscreen/area sessions, delayed tasks, and session identity lived directly on `CapturePipeline`, which kept the refactor surface coupled even after moving behavior into helpers.
- The async frozen-snapshot path and delayed countdown path both depended on shared state cleanup that was hard to reason about when spread across `CapturePipeline` extensions.

## Fixes Applied
- Added [CaptureEntrypointService.swift](/Users/b/Caloura/Caloura/App/CaptureEntrypointService.swift) and [CaptureEntrypointService+OverlaySessions.swift](/Users/b/Caloura/Caloura/App/CaptureEntrypointService+OverlaySessions.swift) so area/fullscreen/window/repeat/delayed capture entry logic, first-overlay metrics, stale callback guards, and interrupted-capture teardown live together.
- Added [CaptureSessionState.swift](/Users/b/Caloura/Caloura/App/CaptureSessionState.swift) as the shared owner of overlay/session references, delayed countdown task ownership, tracked capture-session IDs, and first-mouse-down bookkeeping.
- Added [CapturePipeline+SessionState.swift](/Users/b/Caloura/Caloura/App/CapturePipeline+SessionState.swift) so `CapturePipeline` exposes narrow helpers around the shared session container while keeping its public façade intact.
- Updated [CapturePipeline+EntryPoints.swift](/Users/b/Caloura/Caloura/App/CapturePipeline+EntryPoints.swift) to delegate entry/session orchestration to the new service and leave only low-level capture operations in the extension.
- Updated [CapturePipeline+ScrollCapture.swift](/Users/b/Caloura/Caloura/App/CapturePipeline+ScrollCapture.swift) to reuse the shared tracked-session and first-mouse-down helpers, so stale overlay callbacks and metric bookkeeping stay consistent with the new entrypoint flow.
- Added [CapturePipelineEntryPointLifecycleTests.swift](/Users/b/Caloura/CalouraTests/AppTests/CapturePipelineEntryPointLifecycleTests.swift) with focused coverage for cancelled frozen-image updates, fullscreen multi-display cancellation symmetry, and delayed countdown task cleanup.
- Regenerated [project.pbxproj](/Users/b/Caloura/Caloura.xcodeproj/project.pbxproj) so the new source and test files are included in Xcode builds.

## Validation Evidence
- `xcodegen generate`
- `swift build`
- `swiftlint lint --quiet`
- `swift test`
- `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
