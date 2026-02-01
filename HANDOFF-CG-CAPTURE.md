# Caloura — CG Capture Fallback Implementation

## Summary

ScreenCaptureKit (SCK) requires hardened runtime and stable code signing. In debug builds with ad-hoc signing, SCK always fails. A three-tier fallback chain was implemented: SCK, `screencapture` CLI, and CoreGraphics. The CG path produces images but only captures desktop wallpaper and Caloura's own windows — other apps are missing due to TCC restrictions.

**Root cause**: macOS Sequoia TCC identifies apps by code signing identity + bundle ID. Ad-hoc signed builds get a new identity on every build, so TCC never recognizes them as having screen recording permission.

**Resolution**: Stable code signing was added to `project.yml` (Team ID, Apple Development identity, automatic signing). This is the same approach used by Shottr and CleanShot X.

---

## TCC Behavior by API

| API | Ad-hoc Result | Why |
|-----|---------------|-----|
| `CGPreflightScreenCaptureAccess()` | `false` | Binary identity doesn't match TCC entry |
| `SCShareableContent` | Throws "user declined TCCs" | Requires stable signing |
| `CGWindowListCopyWindowInfo` | Returns window names | Less strictly gated |
| `CGWindowListCreateImage` | Own windows only | Pixel capture requires TCC match |
| `CGDisplayCreateImage` | Desktop wallpaper only | Most restricted |
| `/usr/sbin/screencapture` | "could not create image" | Needs own TCC entry on Sequoia |

---

## Fallback Chain

```
SCK → screencapture CLI → CoreGraphics → throw .noPermission
```

Each tier falls through on failure. The `sckFailed` flag prevents repeated SCK attempts after the first failure.

---

## Files Changed

### New File
- **`Caloura/Capture/CaptureWindow.swift`** — Unified window type for SCK + CG paths. Holds `CGWindowID`, title, app name, and optional `SCWindow` reference.

### ScreenCaptureManager.swift (Major Rewrite)

**Removed**: `verifySCKAccess()`, `sckAuthorized` cache, `resetSCKCache()`

**Added**:
- `sckFailed: Bool` flag, set on first SCK failure
- `checkSCKAccess()` for passive permission checking
- `screencapture` CLI fallback via `runScreencapture(args:)` — spawns `/usr/sbin/screencapture` in `Task.detached`, loads PNG into `Data` before deleting temp file, uses `kCGImageSourceShouldCacheImmediately` to prevent lazy-load crashes
- CG fallback methods: `cgCaptureFullScreen`, `cgCaptureArea`, `cgCaptureWindow`
- CG window enumeration: `getWindowsCG()`
- Public methods: try SCK, then screencapture, then CG, then throw

**API changes**: `captureWindow()` and `getWindows()` now use `CaptureWindow` instead of `SCWindow`.

### WindowPicker.swift
- Migrated from `SCWindow` to `CaptureWindow`
- Removed `import ScreenCaptureKit`

### CapturePipeline.swift
- Removed `verifySCKAccess()` pre-checks from all capture methods
- Added `CaptureError.noPermission` handling with permission alert
- Migrated to `CaptureWindow` type

---

## Current Status

All items from the original "Approaches to Investigate" section have been resolved:

| Approach | Outcome |
|----------|---------|
| Stable debug signing | **Implemented** — `project.yml` now has `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`, `CODE_SIGN_STYLE` |
| screencapture from within Caloura | Tested — fails due to TCC "responsible process" |
| CGWindowListCreateImage with specific window IDs | Tested — still blocked by TCC |
| Toggle permission in System Settings | Works, but not a viable user-facing solution |
| macOS Sequoia TCC workarounds | No workaround exists; stable signing is the only path |

---

## Build

```bash
cd /Users/b/Caloura
xcodebuild -scheme Caloura -configuration Debug build
```
