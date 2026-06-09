# Audit Closure: 2026-06-09

Status: closed for this exploration pass.

Validation:
- `swift build` passed
- `swiftlint lint --quiet` passed with warning-level lint already present in the workspace
- `swift test` passed: 685 tests, 0 failures

## Fixed

- Window sharing stealth: all Caloura-owned windows and panels now call `excludeFromScreenSharing()`.
- App activation stealth: `SingleWindowPresenter` activation is explicit via `activateApp`.
- Cursor maintenance power: maintenance reprime interval widened from 50 ms to 350 ms while preserving event-driven reprime paths.
- Window shareable-content prewarm power: app activation no longer prewarms ScreenCaptureKit content unless there was recent window-capture activity.
- Permission repair polling power: settings-return validation defaults to one live SCK validation per outer tick.
- User-facing error polish: update, clipboard, save, pinned, beautify, redaction, history, and annotation surfaces now use friendlier error copy where user-visible.
- History context-menu no-ops: Open, Copy, and Show in Finder disable when a capture has no file path.
- Beautify preview correctness: Copy/Save are disabled while preview output is unavailable, processing clears with `defer`, and preview theme changes persist to settings.
- Diagnostics toggle copy: Preferences now describes local MetricKit behavior accurately.
- Update manager quality: removed production/test Combine usage and replaced it with a small KVO observation seam.
- Preview clear power: replaced the run-loop timer with a cancellable task.
- Clipboard auto-clear power: replaced the sleeping task with a cancellable `DispatchWorkItem`.
- Beautify power: large bitmap beautify work now runs at `.utility` priority.
- Capture-event log stealth: capture start/success and SCK probe timing logs were demoted to debug.
- Filename stealth: added a timestamp-only filename setting that omits source app and smart AI names.
- Smart metadata privacy/power: generation checks `SystemLanguageModel.default.isAvailable`, documents the on-device assumption, and uses a short-lived session.
- Diagnostics persistence stealth: MetricKit diagnostic payloads are now written through `HistoryCrypto`.
- OCR power: bounding-box OCR now runs a fast pre-scan before the accurate pass.
- UI polish: license Return-to-activate, annotation Esc cancel, redaction progress, auto-clear preference, grouped onboarding keycaps, icon tooltips, X label, and recent-activity separator.
- Quality cleanup: injected `PresetManager` defaults, injected `HistoryView` settings, extracted cursor-rect reset helper, moved hotkey migration keys into `AppSettings.Keys`, disabled CIContext intermediates, and removed listed production force unwraps.
- Release verification: the UI-test host window remains `#if DEBUG`, and the activation-policy branch is only reachable through the UI-test launch path.

## Intentionally Deferred

- Sparkle-owned update windows are still dependency-owned. Caloura-owned windows are hardened; fully hiding Sparkle UI needs a custom public `SPUUserDriver`.
- `PermissionCoordinator` file splitting, `OnboardingView` / `AnnotationOverlay` controller splitting, and `CaptureEntrypointService` dependency slicing are larger structural refactors. They remain quality follow-ups because folding them into this exploration pass would increase regression risk without changing shipped behavior.
- KeyboardShortcuts' change notification still uses the package's string name because the package's `.shortcutByNameDidChange` symbol is not public API.
- Logger consolidation across `+` files and removal of test-only `CapturePerformanceSummary` are housekeeping follow-ups with no runtime behavior impact.
- `ScreenCaptureManager+Permission.captureMinimalScreenshot` still wraps the completion-handler API locally because it is already isolated to a named async probe seam.
- Onboarding and small-dialog fixed frames remain a large-text polish follow-up.

## Residual Manual Checks

- Live focus/Cmd-Tab behavior for passive prompts should still be smoke-tested in the app.
- Cursor race behavior should be manually smoke-tested around area/fullscreen capture after the maintenance interval change.
- Sparkle update UI stealth remains a product decision if dependency-owned windows must also be hidden from screen sharing.
