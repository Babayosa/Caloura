# Task 22 — Code Review Fixes (7 Issues)

Date: 2026-02-21
Owner: Caloura Engineering
Status: Complete

## Issue 4: Extract resolveScreen() helper

- [x] Added `ResolvedScreen` struct and `resolveScreen()` to `ScreenCaptureManager.swift`
- [x] Updated `sckCaptureFullScreen`, `sckCaptureArea` in `+SCKCapture.swift`
- [x] Updated `screencaptureFullScreen`, `screencaptureArea` in `+CLICapture.swift`

## Issue 1: Remove dead CG fallback, surface meaningful errors (Major)

- [x] Deleted `ScreenCaptureManager+CGCapture.swift`
- [x] `captureFullScreen()`: removed CG fallback, throws CLI error or `.noPermission`
- [x] `captureArea()`: same pattern

## Issue 3: Make alertPresenter async

- [x] `AlertPresenter` typealias → `(PermissionState) async -> Void`
- [x] `handleCapturePermissionFailure()` → `async`
- [x] `HandlePermissionFailureFn` → `@MainActor () async -> Void`
- [x] `performCapture()`: `await handlePermissionFailure()` in `.noPermission` catch
- [x] Updated production init, test helpers, PermissionCoordinator tests

## Issue 2: Replace UnsafeMutablePointer

- [x] Replaced manual pointer allocation with `var activationObserver: NSObjectProtocol?`

## Issue 5: Extract closeAll closure in overlays

- [x] `CaptureOverlayWindow.showOnAllScreens()`: extracted `closeAll` closure
- [x] `ScreenSelectionOverlayWindow.showOnAllScreens()`: same pattern

## Issue 6: Extract HistorySearchModel

- [x] Created `Caloura/UI/HistorySearchModel.swift` with `filteredScreenshots()` and `matchesSubstring()`
- [x] Updated `HistoryView` to delegate to `HistorySearchModel`
- [x] Created `CalouraTests/UITests/HistorySearchModelTests.swift` (14 tests)

## Issue 7: Add FileOrganizer tests + symlink fix

- [x] Added: file permissions (0o600), directory permissions (0o700), JPEG format
- [x] Added: symlink escape rejection, timestamp in filename, sanitization (7 new tests)
- [x] Fixed `validatePathSafety` to check existing ancestors for symlink escapes

## Review / Evidence

- **Build**: `xcodebuild build` — BUILD SUCCEEDED
- **Tests**: `swift test` — 335 tests, 0 failures
- **Lint**: `swiftlint lint --quiet` — 0 new warnings (pre-existing only)

### Files Modified

| Action | File | Issue |
|--------|------|-------|
| EDIT | `Caloura/Capture/ScreenCaptureManager.swift` | 4, 1 |
| EDIT | `Caloura/Capture/ScreenCaptureManager+SCKCapture.swift` | 4 |
| EDIT | `Caloura/Capture/ScreenCaptureManager+CLICapture.swift` | 4 |
| DELETE | `Caloura/Capture/ScreenCaptureManager+CGCapture.swift` | 1 |
| EDIT | `Caloura/Capture/PermissionCoordinator.swift` | 3 |
| EDIT | `Caloura/App/CapturePipeline.swift` | 3 |
| EDIT | `CalouraTests/Helpers/CapturePipelineTestHelpers.swift` | 3 |
| EDIT | `CalouraTests/AppTests/PermissionCoordinatorTests.swift` | 3 |
| EDIT | `CalouraTests/AppTests/PermissionCoordinatorEdgeCaseTests.swift` | 3 |
| EDIT | `Caloura/Capture/CaptureOverlayWindow.swift` | 2, 5 |
| EDIT | `Caloura/Capture/ScreenSelectionOverlayWindow.swift` | 5 |
| NEW | `Caloura/UI/HistorySearchModel.swift` | 6 |
| EDIT | `Caloura/UI/HistoryView.swift` | 6 |
| NEW | `CalouraTests/UITests/HistorySearchModelTests.swift` | 6 |
| EDIT | `Caloura/Distribution/FileOrganizer.swift` | 7 |
| EDIT | `CalouraTests/DistributionTests/FileOrganizerTests.swift` | 7 |
