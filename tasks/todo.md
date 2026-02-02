# Fix: Captures only show desktop wallpaper (permission false positive)

## Plan

- [x] Remove `hasAnyPermissionSignal()` guard from `captureFullScreen`, `captureArea`, `captureWindow`
- [x] Gate CG fallback behind `checkPermission()` (CGPreflight) instead
- [x] Always try screencapture CLI after SCK fails (no permission gate needed)
- [x] Fix `getWindows()` to use `checkPermission()` instead of `hasAnyPermissionSignal()`
- [x] Delete `hasAnyPermissionSignal()` and `checkCGWindowListFallback()` methods
- [x] Update `OnboardingView.swift` — replace `hasAnyPermissionSignal()` with `checkPermission()`
- [x] Update `plan.md` — log fix in Completed Work and Known Issues
- [x] Verify: `xcodebuild build` — clean compile
- [x] Verify: `xcodebuild test` — 66 tests pass
- [x] Verify: `grep` confirms no remaining references to removed functions

## Review / Evidence

- **Build**: `BUILD SUCCEEDED` — clean compile, no warnings from changes
- **Tests**: 66 tests, 0 failures — `TEST SUCCEEDED`
- **Grep**: `hasAnyPermissionSignal|checkCGWindowListFallback` returns 0 matches in `Caloura/`
- **Files changed**: `ScreenCaptureManager.swift`, `OnboardingView.swift`, `plan.md`
