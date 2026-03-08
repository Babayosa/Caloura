# Task 10: Capture Overlay + Freeze Snapshot Hardening

## Objective
Fix the area-capture regression where entering selection mode can hide all visible windows on built-in and external displays, and harden the frozen-background pipeline so it remains fast without capturing Caloura itself.

## Scope
- Keep instant overlay presentation for area capture
- Replace unsafe freeze snapshot sourcing with ScreenCaptureKit display filters that exclude Caloura
- Move shared selection overlays off `.screenSaver` semantics while keeping non-activating input behavior
- Exclude Caloura from the system window picker
- Add focused tests for the new overlay and freeze behavior

## Out of Scope
- Reworking the final area/fullscreen screenshot path
- Replacing the native ScreenCaptureKit window picker UI
- Broad UI redesigns outside selection overlays

## Validation
- Targeted `xcodebuild test` slice for:
  - `CalouraTests/WindowPickerManagerTests`
  - `CalouraTests/CapturePipelineTests/testCaptureArea_freezeEnabledPresentsWithSuppressedDimmingThenUpdates`
  - `CalouraSystemTests/CaptureSystemTests/testAreaCapturePresentsCrosshairAndHintImmediately`
  - `CalouraSystemTests/CaptureSystemTests/testAreaCaptureUsesNonactivatingOverlayPanelLevel`

## Notes
- Validation was kept intentionally narrow to avoid unnecessary token and log burn while still covering the touched capture seams.
