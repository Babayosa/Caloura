# Task 18: Capture Execution Split

## Objective
Extract the post-capture execution path out of `CapturePipeline` so request resolution, processing, preview publication, distribution, deferred save, and failure handling live in a dedicated internal service while `CapturePipeline` remains focused on entry points and session state.

## Context
- Depends on: `task-17`
- Blocking: none

## Specification
- Files to modify:
  - `Caloura/App/CapturePipeline.swift`
  - `Caloura/App/` capture-related support files as needed
  - focused capture tests under `CalouraTests/AppTests/`
  - `Caloura.xcodeproj/project.pbxproj` if new source files are added
  - `codex/CONTEXT-CHAIN.md`
  - `codex/LESSONS.md`
- Create a narrow internal execution service that owns:
  - `performCapture(...)`
  - capture failure normalization / status messaging
  - image processing and preset resolution after capture
  - preview publication and post-capture distribution
  - deferred save + enrichment completion flow
- Keep `CapturePipeline` responsible for:
  - entry-point orchestration
  - overlay/session mutable state
  - session coordinator creation
  - scroll / area / fullscreen / window capture routing
- Preserve the current UX and perf behavior:
  - raw preview must still appear before deferred enrichment completes
  - permission failures must still route through `handlePermissionFailure`
  - metrics and performance session marks must remain aligned with current stages
- Add focused tests proving the extracted execution service directly preserves:
  - happy-path preview/distribution behavior
  - permission-error handling
  - generic capture failure messaging
  - deferred save/enrichment scheduling behavior

## Acceptance Criteria
- [x] `CapturePipeline` delegates post-capture execution to a dedicated internal service
- [x] Focused capture tests cover the extracted execution service directly
- [x] All validation passes (`swift build`, `swiftlint lint --quiet`, `swift test`)

## Notes
- Do not include the unrelated local edit in `Caloura/UI/OnboardingView+Steps.swift`.
- Keep the task scoped to capture execution flow; do not broaden into entry-point or UI redesign work here.

## Findings
- `CapturePipeline` was still mixing two different responsibilities: hot-path entry/session orchestration and the post-capture execution pipeline that resolves presets, processes images, publishes previews, distributes artifacts, and handles deferred save/enrichment work.
- That coupling made the capture hot path harder to audit and forced most regression coverage through the large `CapturePipelineTests` fixture instead of a smaller execution-focused seam.

## Fixes Applied
- Added [CaptureExecutionService.swift](/Users/b/Caloura/Caloura/App/CaptureExecutionService.swift) as a narrow internal service that owns:
  - `performCapture(...)`
  - capture failure normalization and user/log messaging
  - image processing after request resolution
  - raw preview publication
  - clipboard/sound distribution
  - deferred save plus enrichment scheduling
- Updated [CapturePipeline.swift](/Users/b/Caloura/Caloura/App/CapturePipeline.swift) so the pipeline keeps entry-point routing and mutable capture-session state, while delegating post-capture execution to a lazily constructed `CaptureExecutionService`.
- Added [CaptureExecutionServiceTests.swift](/Users/b/Caloura/CalouraTests/AppTests/CaptureExecutionServiceTests.swift) covering:
  - happy-path preview-before-clipboard behavior
  - permission-error routing
  - generic failure messaging
  - deferred save plus enrichment scheduling
- Regenerated [project.pbxproj](/Users/b/Caloura/Caloura.xcodeproj/project.pbxproj) so the new source and test files are included in Xcode builds.

## Validation Evidence
- `xcodegen generate`
- `swift build`
- `swiftlint lint --quiet`
- `swift test`
- `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
