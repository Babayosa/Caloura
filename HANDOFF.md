# Caloura — Phase 8: Testing & UI Improvements

## Summary

Phase 8 implemented a comprehensive quality pass based on a three-agent audit (QA, UI/UX, Architecture). Includes critical bug fixes, UI polish, expanded automated tests, and medium-effort UI features.

**Build status**: Zero warnings. 61 tests pass (up from 13).

---

## Bug Fixes

### 1. OCR Race Condition
**File**: `CapturePipeline.swift:238-263`

Detached OCR task always updated `recentScreenshots[0]`. Rapid captures caused OCR text from the first capture to overwrite the second. Fixed by capturing the screenshot UUID before dispatch and matching by ID on completion.

### 2. Display Disconnect Crash
**File**: `QuickAccessOverlay.swift:44-50`

`AppState.lastCaptureScreen` held a stale `NSScreen` reference after display unplug. Fixed by validating against `NSScreen.screens` before use, falling back to `NSScreen.main`.

### 3. PinnedScreenshot unpinAll Order
**File**: `PinnedScreenshotWindow.swift:73-88`

Observers were removed before panels were closed, causing callbacks to fire on cleaned-up state. Fixed by reordering: clear tracking state, close panels, then remove observers.

### 4. HistoryWindowController Leak
**File**: `HistoryView.swift:157-185`

`self.window` was never niled on title-bar close, leaking the window and SwiftUI view tree. Fixed with `willCloseNotification` observer.

### 5. AnnotationWindowController Leak
**File**: `AnnotationOverlay.swift:248-290`

Same leak pattern as #4. Fixed with `willCloseNotification` observer.

### 6. Stale State on Permission Denial
**File**: `CapturePipeline.swift:157-162`

`lastScreenshot` persisted after SCK access failure, allowing overlay actions on stale data. Fixed by setting `appState.lastScreenshot = nil` on permission failure.

### 7. SCK Cache Never Invalidates
**File**: `ScreenCaptureManager.swift:32-47`

`sckAuthorized` was cached permanently. Revoking permission left a stale `true`. Fixed by resetting the cache on capture errors.

### 8. Concurrent Captures in MenuBarView
**File**: `MenuBarView.swift:12-54`

Capture buttons were not disabled during active captures. Fixed with `.disabled(appState.isCapturing)` on all capture buttons.

### 9. AppState History Decode Silent Failure
**File**: `AppState.swift:48-54`

`try?` swallowed decode errors, silently losing history. Fixed by logging the error and attempting per-item recovery from the JSON array.

---

## UI Polish

| Change | File | Details |
|--------|------|---------|
| Hover states | `QuickAccessOverlay.swift` | Background highlight on button hover |
| Auto-dismiss 5s to 8s | `QuickAccessOverlay.swift` | More time to read labels |
| Shortcut hints in menu | `MenuBarView.swift` | e.g. `"Capture Area (Ctrl+Shift+4)"` |
| Disabled tooltip | `MenuBarView.swift` | "No previous capture" on Repeat Last Area |
| VoiceOver labels | `QuickAccessOverlay.swift` | Accessibility labels on all overlay buttons |
| History context menu | `HistoryView.swift` | Right-click: Copy, Show in Finder, Delete |
| Resizable preferences | `PreferencesView.swift` | `minWidth`/`minHeight` instead of fixed frame |
| Onboarding key caps | `OnboardingView.swift` | Styled key cap views for shortcuts |
| ESC hint | `RegionSelectionView.swift` | "ESC to cancel" shown during region selection |
| Size label positioning | `RegionSelectionView.swift` | Falls back inside selection if offscreen |
| Async thumbnails | `HistoryView.swift` | `Task.detached` loading prevents UI jank |

---

## Test Coverage

**Before**: 4 files, 13 tests. **After**: 9 files, 61 tests.

### New Test Files

| File | Cases | Coverage |
|------|-------|----------|
| `AppStateTests.swift` | 6 | Insert order, 50-item limit, clear, persistence, ID preservation |
| `URLSchemeHandlerTests.swift` | 12 | All route types, invalid schemes, preset normalization |
| `PresetManagerTests.swift` | 8 | Lookup, category mapping, built-in preset init |
| `ImageProcessorTests.swift` | 4 | PNG/JPEG/TIFF magic bytes, correct dimensions |
| `ScreenshotItemTests.swift` | 4 | Codable round-trip, Hashable, minimal-field decode |

### Expanded Test Files

| File | Added | Coverage |
|------|-------|----------|
| `SmartCropperTests.swift` | +3 (5 total) | autoCrop integration, min size, below-threshold nil |
| `FileOrganizerTests.swift` | +3 (7 total) | save-to-disk, subfolder creation, special chars |

---

## Medium-Effort UI Features

### Annotation Undo/Redo
**File**: `AnnotationOverlay.swift`

Full undo/redo stack storing annotation arrays. Toolbar buttons for undo (Cmd+Z) and redo (Shift+Cmd+Z) with appropriate disabled states.

### Pinned Window Toolbar
**File**: `PinnedScreenshotWindow.swift`

Copy and Close buttons on each pinned window. Copy writes to pasteboard; Close dismisses the panel.

---

## Remaining Work

### Tests Requiring Protocol Extraction
- Extract `ScreenCapturing` protocol from `ScreenCaptureManager`
- Extract `ClipboardWriting` protocol from `ClipboardManager`
- Write `CapturePipelineTests` (~12 cases) and `ClipboardManagerTests` (~5 cases)

### Tests Requiring Screen Recording Permission
- Integration tests for `captureFullScreen()`, `captureArea()`, `getWindows()`

### Known Issues

| Issue | Severity | Status |
|-------|----------|--------|
| `isReleasedWhenClosed = false` on CaptureOverlayWindow | Medium | Open — may prevent deallocation |
| No delayed capture cancellation | Low | Open |
| Private selector `showSettingsWindow:` | Low | Open — undocumented API |
