# Multi-Display Fullscreen Capture + Window Picker Visual Overhaul

## Plan

### Feature 1: Multi-Display Full Screen Capture
- [x] Create `ScreenSelectionView.swift` — per-display overlay with tracking area, highlight states, display name pill
- [x] Create `ScreenSelectionOverlayWindow.swift` — NSWindow wrapper with `showOnAllScreens()` static method
- [x] Modify `CapturePipeline.swift` — add `screenOverlays` property, branch on screen count, pass screen to capture
- [x] Add `screen` parameter to `performFullscreenCapture()` (default nil preserves single-display path)

### Feature 2: Window Picker Visual Overhaul
- [x] Add `appIcon: NSImage?` field to `CaptureWindow`
- [x] Populate `appIcon` in SCK path (`getWindows()`)
- [x] Populate `appIcon` in CG path (`getWindowsCG()`)
- [x] Rewrite `WindowSelectionView` styling — 45% overlay, white border, glow layers, rounded-rect cutout, no fill
- [x] Replace `drawLabel` with `drawWindowLabel` — icon + bold app name + em dash + title at 70% opacity
- [x] Update `drawHintLabel` — middle dot separator, 55% background, 8pt corners, y=24

### Verification
- [x] `xcodebuild build` — clean compile
- [x] `xcodebuild test` — all 66 tests pass

## Review / Evidence

- **Build**: `BUILD SUCCEEDED` — no new warnings (only pre-existing CGWindowListCreateImage deprecation warnings)
- **Tests**: `Executed 66 tests, with 0 failures (0 unexpected) in 0.186 seconds`
- **Files created**: `ScreenSelectionView.swift`, `ScreenSelectionOverlayWindow.swift`
- **Files modified**: `CapturePipeline.swift`, `CaptureWindow.swift`, `ScreenCaptureManager.swift`, `WindowSelectionView.swift`
- **Bug fix during implementation**: `String.flatMap` was iterating characters instead of using `Optional.flatMap` on `bundleIdentifier` — fixed by using closure + guard pattern instead
