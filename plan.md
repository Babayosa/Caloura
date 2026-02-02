# Caloura — Project Plan

## Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Feature Inventory](#feature-inventory)
- [Completed Work](#completed-work)
- [Release Pipeline](#release-pipeline)
- [Ship Checklist](#ship-checklist)
- [Known Issues](#known-issues)
- [Decisions Log](#decisions-log)

---

## Project Overview

Caloura is a macOS menu-bar screenshot tool. It captures screen regions, windows, and full screens, with OCR, annotation, pinning, presets, and clipboard integration.

**Audience**: Educators, students, and knowledge workers — teaching artifacts, lab/study workflows, lecture documentation.

**Distribution**: Direct download via Gumroad (not App Store). Notarized and stapled for Gatekeeper.

**Platform**: macOS 14.0+ (Sonoma)
**Language**: Swift 5.9 / SwiftUI
**Build system**: XcodeGen (`project.yml`) + Swift Package Manager
**Dependencies**: KeyboardShortcuts, Sparkle
**Bundle ID**: `com.caloura.app`
**Team ID**: `NG4ML6Q47T`

---

## Architecture

### Source Layout

```
Caloura/
├── App/             CalouraApp, AppDelegate, CapturePipeline, UpdateManager, URLSchemeHandler
├── Capture/         ScreenCaptureManager, CaptureWindow, RegionSelectionView, WindowPicker
├── Context/         Preset system, ContextDetector
├── Distribution/    FileOrganizer, ClipboardManager, MarkdownExporter
├── HotKeys/         HotKeyManager
├── Models/          AppState, ScreenshotItem, AppSettings, CaptureContext
├── Processing/      ImageProcessor, SmartCropper, OCREngine
├── Resources/       Info.plist, entitlements, assets
└── UI/              MenuBarView, HistoryView, PreferencesView, OnboardingView, overlays
```

### Capture Pipeline

```
HotKey / Menu / URL Scheme
    → CapturePipeline
        → ScreenCaptureManager
            → SCK (primary)
            → screencapture CLI (fallback)
            → CoreGraphics (last resort, deprecated macOS 15)
        → ImageProcessor (smart crop optional)
        → FileOrganizer (save to disk)
        → ClipboardManager (copy)
        → QuickAccessOverlay (post-capture toolbar)
        → OCREngine (async, background, updates history by UUID)
```

### Key Design Decisions

- **Menu-bar only** (`LSUIElement: true`) — no dock icon
- **No sandbox** — required for screen recording APIs
- **Hardened runtime** — required for notarization
- **Sparkle for updates** — standard for non-App Store Mac apps
- **XcodeGen** — `project.yml` is the source of truth; `.xcodeproj` is generated
- **ID-only equality on ScreenshotItem** — explicit `==` and `hash(into:)` use only `id`, supporting mutable title/tags without breaking identity

---

## Feature Inventory

All features below are implemented and verified in code. No stubs or TODOs.

### Capture
| Feature | Key files |
|---------|-----------|
| Region capture | `ScreenCaptureManager.swift`, `RegionSelectionView.swift`, `CaptureOverlayWindow.swift` |
| Window capture | `ScreenCaptureManager.swift`, `WindowPicker.swift` |
| Fullscreen capture | `ScreenCaptureManager.swift` |
| Repeat last area | `CapturePipeline.swift` (stores last rect/screen) |
| Delayed capture (3–10 s) | `CapturePipeline.swift` |
| Three-tier fallback | SCK → screencapture CLI → CoreGraphics |

### Processing
| Feature | Key files |
|---------|-----------|
| Smart crop (Vision saliency + border trim) | `SmartCropper.swift` |
| OCR (async, background) | `OCREngine.swift`, `CapturePipeline.swift` |
| Image processing (PNG) | `ImageProcessor.swift` |

### Distribution
| Feature | Key files |
|---------|-----------|
| Clipboard (image, Markdown, citation, multi-format) | `ClipboardManager.swift`, `MarkdownExporter.swift` |
| File export (PNG, date/subfolder organization) | `FileOrganizer.swift` |
| Quick access overlay (5 actions, 8 s auto-dismiss) | `QuickAccessOverlay.swift` |

### History & Metadata
| Feature | Key files |
|---------|-----------|
| Searchable history (app, window title, OCR text, filename, tags) | `HistoryView.swift`, `AppState.swift` |
| Titles (auto from window/app, user-editable) | `ScreenshotItem.swift`, `HistoryView.swift` |
| Tags (user-defined, case-insensitive dedup) | `ScreenshotItem.swift`, `HistoryView.swift` |
| Thumbnail downsampling (320 px CGImageSource) | `HistoryView.swift` |
| Backward-compatible Codable (decodeIfPresent) | `ScreenshotItem.swift` |
| Partial recovery on corrupt data | `AppState.swift` |

### UI
| Feature | Key files |
|---------|-----------|
| Menu bar (capture, repeat, delay, presets, system) | `MenuBarView.swift` |
| Annotation (arrow, rectangle, highlight, undo/redo) | `AnnotationOverlay.swift` |
| Pinned windows (always-on-top NSPanel) | `PinnedScreenshotWindow.swift` |
| Preferences (General, Shortcuts, Presets, About) | `PreferencesView.swift` |
| Onboarding (4-step, permission polling) | `OnboardingView.swift` |

### Automation
| Feature | Key files |
|---------|-----------|
| URL scheme (`caloura://capture`, `copy`, `history`, `settings`) | `URLSchemeHandler.swift` |
| Presets (4 built-in: Quick Capture, Lecture Notes, Code Snippet, Assignment) | `PresetManager.swift` |
| Context detection (auto-categorize app, auto-select preset) | `ContextDetector.swift` |
| Keyboard shortcuts (customizable, KeyboardShortcuts framework) | `HotKeyManager.swift` |

### System
| Feature | Key files |
|---------|-----------|
| Sparkle auto-updates (check for updates, disabled if no feed URL) | `UpdateManager.swift` |
| Permission re-check on app activation | `CalouraApp.swift` (AppDelegate) |
| Two-state permission alerts (never granted vs. granted-but-failing) | `ScreenCaptureManager.swift` |

---

## Completed Work

### Core Capture & Permissions
- Three-tier fallback chain (SCK → screencapture CLI → CoreGraphics) with `CaptureWindow` abstraction
- Stable code signing: `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE: Automatic`, split identity (Debug: Apple Development, Release: Developer ID Application)
- Hardened runtime enabled, sandbox disabled
- Permission re-check on `applicationDidBecomeActive` via `checkSCKAccess()`
- Two-path permission alert: deep-links to System Settings for "never granted", offers restart for "granted but failing"
- Onboarding 4-step flow with 2-second permission polling

### History & Data Integrity
- Thumbnail downsampling: `CGImageSourceCreateThumbnailAtIndex` at 320 px max (memory: ~400 KB per thumbnail vs ~30–60 MB for full image)
- Tap gesture fix: double-tap before single-tap to resolve gesture ambiguity
- `saveHistory()` made internal, called after every mutation (7 call sites: add, clear, title edit, tag add, tag remove, context menu delete, OCR update)
- Partial recovery on corrupt JSON (`AppState.loadHistory` salvages readable items)
- Titles auto-populated from capture context (window title → app name → "Untitled"), user-editable
- Tags: user-defined, case-insensitive deduplication (preserves display case)
- ID-only Equatable/Hashable on ScreenshotItem (supports mutable fields without breaking identity)

### UI & Overlays
- Annotation tools with undo/redo stacks (Cmd+Z / Cmd+Shift+Z)
- Pinned windows: always-on-top NSPanel with copy/close toolbar, space-spanning
- Quick access overlay: 5 actions (copy, markdown, citation, annotate, pin), 8 s auto-dismiss
- PreferencesWindowController replaces undocumented `showSettingsWindow:` selector
- All ARC-managed windows set `isReleasedWhenClosed = false` to prevent `objc_release` double-free crash

### Sparkle & Updates
- UpdateManager singleton with auto-starting updater
- `canCheckForUpdates` bound via Combine publisher
- "Check for Updates" menu item, disabled when no feed URL configured

### Build & Test
- XcodeGen `project.yml` as source of truth
- `release.sh`: archive → export → notarize (with `--wait`) → staple → zip
- Test target signing fix (DEVELOPMENT_TEAM on CalouraTests)
- 66 tests across 9 files, 0 failures

### Rebrand: SnapNote → Caloura
- Full atomic rename across directories, build config, Swift source (13 files), tests (9 files), scripts, documentation
- UserDefaults keys left generic (no brand in key names) — no data migration needed
- Verified: `grep -ri "snapnote"` returns zero matches

### P1 Bug Fix Pass (audit-driven)
- **Image format picker**: `FileOrganizer.save()` now accepts `imageFormat` parameter, encodes via `ImageProcessor` (PNG/JPEG/TIFF), uses correct file extension. `CapturePipeline` passes `settings.imageFormat`.
- **History search**: Added `item.title` to `filteredScreenshots` filter — user-edited titles are now searchable.
- **Silent save failures**: Replaced `try?` with `do-catch` + `Self.logger.error` in `AppState.saveHistory()`.
- **Delete confirmation**: Context menu delete now sets `itemToDelete` state and presents a confirmation alert before removal.
- **SCK scale factor**: `sckCaptureFullScreen` uses `targetScreen.backingScaleFactor` instead of hardcoded `* 2`.
- All 5 fixes verified: 66 tests pass, 0 failures.

### Window Over-Release Crash Fix (P0)
- **Root cause**: `NSWindow.isReleasedWhenClosed` defaults to `true`. When `close()` is called, AppKit sends an extra `release` that ARC doesn't track. Subsequent `= nil` on the strong reference sends a second `release` on a freed object → `EXC_BAD_ACCESS` in `objc_release`.
- Added `isReleasedWhenClosed = false` to all ARC-managed windows:
  - `CaptureOverlayWindow` (init)
  - `QuickAccessOverlay` (panel creation)
  - `HistoryWindowController` (window creation)
  - `PreferencesWindowController` (window creation)
  - `OnboardingWindowController` (window creation)
- `PinnedScreenshotWindow` already had the fix (long-lived panel).
- 66 tests pass, 0 failures.

---

## Release Pipeline

### Prerequisites (one-time, before first release)

| # | Step | Command / Action | Verification |
|---|------|-----------------|--------------|
| 1 | Developer ID Application certificate | Create at developer.apple.com → Certificates | `security find-identity -v -p codesigning \| grep "Developer ID Application"` |
| 2 | Store notarization credentials | `xcrun notarytool store-credentials "Caloura-Notarize" --apple-id <email> --team-id NG4ML6Q47T --password <app-specific-password>` | `xcrun notarytool credentials list` shows `Caloura-Notarize` |
| 3 | Sparkle EdDSA key (for auto-updates) | Download Sparkle release, run `./bin/generate_keys` | Public key printed; add to `project.yml` as `SUPublicEDKey` |
| 4 | Appcast hosting (for auto-updates) | Create GitHub Pages repo, add URL to `project.yml` as `SUFeedURL` | URL returns valid XML |

Steps 1–2 are required for any release. Steps 3–4 are required for auto-updates to function.

### Build & Release

```bash
./scripts/release.sh 1.0.0
# Produces: build/Caloura-1.0.0.zip (notarized + stapled)
# Upload to Gumroad
```

**What `release.sh` does** (all steps abort on failure via `set -euo pipefail`):
1. Validates version argument
2. Regenerates Xcode project (`xcodegen generate`)
3. Archives with Release configuration (`xcodebuild archive`)
4. Exports with Developer ID (`xcodebuild -exportArchive` using `scripts/ExportOptions.plist`)
5. Verifies code signature (`codesign --verify --deep --strict`)
6. Submits for notarization (`xcrun notarytool submit --wait`)
7. Staples ticket (`xcrun stapler staple`)
8. Creates final zip (`ditto -c -k --keepParent`)

### Clean Machine Verification

After building, test on a separate Mac (or clean user account):
1. Download and unzip `Caloura-1.0.0.zip`
2. `xcrun stapler validate Caloura.app` — should show "The validate action worked!"
3. `codesign -vv Caloura.app` — should show valid Developer ID signature
4. Double-click to launch — no Gatekeeper warning
5. Grant screen recording permission, take a capture

---

## Ship Checklist

### P0 — Cannot Ship Without

| Item | Status | Acceptance Criteria |
|------|--------|-------------------|
| Developer ID certificate provisioned | **TODO** | `security find-identity` shows cert |
| Notarization credentials stored | **TODO** | `release.sh` completes notarization step |
| `release.sh` end-to-end success | **TODO** | Zip opens on clean Mac, no Gatekeeper warning |
| Gumroad product page | **TODO** | Download link works, product description accurate |

### P1 — Fix Before Ship (all resolved)

| Item | Status | Details |
|------|--------|---------|
| Image format picker has no effect | **DONE** | `FileOrganizer.save()` now accepts `imageFormat` parameter, encodes as PNG/JPEG/TIFF via `ImageProcessor`, uses correct file extension. `CapturePipeline` passes `settings.imageFormat`. |
| History search omits `item.title` | **DONE** | Added `item.title` to `filteredScreenshots` filter in `HistoryView.swift`. |
| Silent `saveHistory()` failures | **DONE** | Replaced `try?` with `do-catch` + `Self.logger.error` in `AppState.saveHistory()`. |
| No delete confirmation in history | **DONE** | Added confirmation alert before history delete via `itemToDelete` state + `.alert()` modifier. |
| Fullscreen SCK hardcodes `* 2` | **DONE** | Replaced `* 2` with `Int(targetScreen.backingScaleFactor)` in `sckCaptureFullScreen`. |

### P2 — Polish (explicitly out of v1 scope)

| Item | Notes |
|------|-------|
| Delayed capture cannot be cancelled | Once countdown starts, no abort. Acceptable for v1. |
| Annotation rendering dual paths | SwiftUI preview vs AppKit export are separate implementations. Risk of visual mismatch. |
| No "Launch at Login" preference | Expected for menu-bar apps. Can add in v1.1. |
| No brush width adjustment in annotations | Hard-coded 3 pt line width. |
| Title not auto-populated for fullscreen captures | Only window/area captures get app context. |
| Custom presets not user-creatable | 4 built-in only. Intentional scope limit for v1. |

### Auto-Updates (post-v1, separate track)

| Item | Dependency |
|------|-----------|
| Generate Sparkle EdDSA key | Download Sparkle release |
| Add `SUPublicEDKey` to `project.yml` info properties | Key from step above |
| Create appcast hosting (GitHub Pages) | Repository creation |
| Add `SUFeedURL` to `project.yml` info properties | Hosting URL from step above |
| Add `generate_appcast` step to release workflow | Sparkle tooling |
| Test update flow: publish v1.0.0, then v1.0.1 | All above complete |

---

## Known Issues

| Issue | Severity | File | Notes |
|-------|----------|------|-------|
| ~~Image format picker has no effect~~ | ~~P1~~ | `FileOrganizer.swift` | **Fixed** — format honored via `imageFormat` parameter |
| ~~Search omits user-edited title~~ | ~~P1~~ | `HistoryView.swift` | **Fixed** — `item.title` added to search filter |
| ~~Silent saveHistory() failure~~ | ~~P1~~ | `AppState.swift` | **Fixed** — `do-catch` with `logger.error` |
| ~~No delete confirmation~~ | ~~P1~~ | `HistoryView.swift` | **Fixed** — confirmation alert before delete |
| ~~Fullscreen SCK hardcodes 2x scale~~ | ~~P1~~ | `ScreenCaptureManager.swift` | **Fixed** — uses `backingScaleFactor` |
| Delayed capture not cancellable | P2 | `CapturePipeline.swift:110-134` | Documented, low impact |
| CGWindowListCreateImage deprecated | Info | `ScreenCaptureManager.swift:416+` | Expected — retained for macOS 14 fallback |

---

## Decisions Log

| Decision | Rationale |
|----------|-----------|
| Gumroad for distribution | Simpler than App Store; screen recording requires non-sandboxed app; supports free/pay-what-you-want for education |
| No App Store | Screen recording permission is incompatible with App Store sandbox |
| Sparkle for auto-updates | Industry standard for non-App Store Mac apps; already a dependency |
| GitHub Pages for appcast | Free, reliable, no server to maintain |
| Developer ID signing (not ad-hoc) | Required for notarization and persistent TCC permissions |
| Keep CG fallback code | Graceful degradation on macOS 14; remove when deployment target is 15.0+ |
| `CGImageSourceCreateThumbnailAtIndex` for history | Reduces memory from ~3 GB to ~20 MB for 50 thumbnails |
| macOS 14.0 minimum for v1 | Education IT lags 12–18 months on OS upgrades; CG fallback is isolated; drop in v2 when macOS 14 is two versions behind |
| Case-insensitive tag dedup | Store as-entered, deduplicate by lowercased comparison. Avoids case-variant accumulation. |
| Rebrand SnapNote → Caloura | Product identity change before public launch. Atomic pass, no data migration (UserDefaults keys are generic). |
| Image format setting implemented | `FileOrganizer.save()` now respects `AppSettings.imageFormat` (PNG/JPEG/TIFF). Uses `ImageProcessor` encoding methods and correct file extension. |
| Auto-updates not blocking v1 | Sparkle integration is correct but unconfigured (no feed URL, no keys). Ship v1 without auto-updates; add in v1.1. |
| History stores max 50 items | UserDefaults JSON, ~50–100 KB. Adequate for v1; consider SQLite if limits increase. |
| 4 built-in presets only | Custom presets are scope creep for v1. Built-ins cover core education workflows. |
