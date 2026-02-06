# Task 18 — Fix Crosshair Cursor Race + QuickAccessOverlay UX

Date: 2026-02-06
Owner: Caloura Engineering
Status: Complete

## Plan Checklist

### Worker A: Fix Crosshair Cursor Race
- [x] A1. Add `cursorUpdate(with:)` override to RegionSelectionView.swift
- [x] A2. Add `mouseMoved(with:)` override for belt-and-suspenders re-assertion
- [x] A3. Add one-shot `didBecomeActiveNotification` observer in CaptureOverlayWindow

### Worker B: Fix QuickAccessOverlay UX
- [x] B1. Add hover callback parameter to QuickAccessOverlayView
- [x] B2. Add `.onHover` to outer container in SwiftUI view
- [x] B3. Add `handleHover(_:screenshot:)` method to QuickAccessOverlay class
- [x] B4. Pass hover callback when creating the SwiftUI view
- [x] B5. Bump dismiss timer from 3s to 6s
- [x] B6. Fix panel sizing — use fittingSize instead of hardcoded 380x52

### Manager: Verification Gate
- [x] C1. `swift build` — clean, zero warnings
- [x] C2. `swift test` — 224 tests, 0 failures
- [x] C3. `swiftlint lint --quiet` — zero warnings
- [x] C4. Update tasks/lessons.md
- [x] C5. Manual verification — crosshair appears every time, overlay hover works

## Verification / Evidence

```
$ swift build
Build complete! (0.86s)

$ swift test
Executed 224 tests, with 0 failures (0 unexpected) in 4.232 (4.251) seconds

$ swiftlint lint --quiet
(no output — clean)
```

**Files changed:**
- `Caloura/Capture/CaptureOverlayWindow.swift` — One-shot didBecomeActiveNotification observer to re-assert crosshair after async activation
- `Caloura/Capture/RegionSelectionView.swift` — Added `cursorUpdate(with:)`, `mouseMoved(with:)` overrides, restored `resetCursorRects` + `.cursorUpdate` tracking
- `Caloura/UI/QuickAccessOverlay.swift` — Hover-pause timer, 6s timeout, fittingSize panel sizing

**Crosshair cursor fix — 4-layer defense:**
1. `push()` in viewDidMoveToWindow — immediate, before activation
2. `resetCursorRects` + `cursorUpdate` override — catches AppKit cursor rect recalculations
3. `didBecomeActiveNotification` observer — fires when activation completes, re-asserts crosshair
4. `mouseMoved` override — forces crosshair on any mouse movement (Firefox/Mozilla approach)

**Failed approach:** `disableCursorRects()` — too aggressive, prevented cursor rect system from ever showing the crosshair. Reverted.
