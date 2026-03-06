# Task 07: Capture UX + Engine Hardening

## Objective
Reduce capture-start latency and ambiguity for area, fullscreen, and window capture while moving post-capture preview and action handling onto a faster, more consistent path.

## Context
- Depends on: task-06
- Blocking: none

## Specification
- Show area/fullscreen capture UI immediately, with explicit mode feedback and crosshair ownership in a session coordinator instead of waiting for frozen screenshots.
- Add capture performance instrumentation for overlay/picker visibility, screenshot time, preview time, clipboard completion, and save completion.
- Move area/fullscreen primary capture to rect-based `SCScreenshotManager.captureImage(in:)`, reserving shareable-content work for window capture only.
- Prewarm window shareable content on activation and before window picker presentation.
- Make raw preview the first pipeline milestone, then finish OCR/PII/history enrichment asynchronously.
- Replace the long fixed quick-access strip with a compact contextual `4 + More` preview chip driven by a shared presentation model and shared quick-action routing.
- Add tests for preview-phase transitions, performance metric aggregation, compact quick-action layout, and rect conversion.

## Acceptance Criteria
- [x] Area capture presents visible mode feedback before frozen screenshots finish loading.
- [x] Area/fullscreen capture use display-space rect capture as the primary SCK path.
- [x] Window picker warm/cold visibility is instrumented and shareable-content prewarm is window-only.
- [x] Raw preview is shown before deferred enrichment work completes.
- [x] Quick-access UI is compact and routes actions through shared pipeline handling.
- [x] `swift build`, `swiftlint lint --quiet`, `swift test`, and `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData` pass.

## Notes
- App-target validation still emits unrelated pre-existing Swift 6 concurrency warnings outside this task’s primary scope, including older scroll-capture and storage warnings.
