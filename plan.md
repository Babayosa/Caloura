# Caloura — Project Plan

## Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Completed Work](#completed-work)
- [Release Pipeline](#release-pipeline)
- [Open Tasks](#open-tasks)
- [Known Issues](#known-issues)
- [Decisions Log](#decisions-log)

---

## Project Overview

Caloura is a macOS menu-bar screenshot tool targeting educators. It captures screen regions, windows, and full screens, with OCR, annotation, pinning, presets, and clipboard integration. Distribution is via Gumroad (direct download, not App Store — screen recording is incompatible with the App Store sandbox).

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
├── Context/         Preset system
├── Distribution/    FileOrganizer, ClipboardManager
├── HotKeys/         HotKeyManager
├── Models/          AppState, ScreenshotItem, AppSettings
├── Processing/      ImageProcessor, SmartCropper, OCR
├── Resources/       Info.plist, entitlements, assets
└── UI/              MenuBarView, HistoryView, PreferencesView, OnboardingView, overlays
```

### Capture Pipeline

```
HotKey → CapturePipeline → ScreenCaptureManager → SCK (primary)
                                                 → screencapture CLI (fallback)
                                                 → CoreGraphics (last resort)
         → ImageProcessor → FileOrganizer → ClipboardManager → QuickAccessOverlay
         → OCR (async, background)
```

### Key Design Decisions

- **Menu-bar only** (`LSUIElement: true`) — no dock icon
- **No sandbox** — required for screen recording APIs
- **Hardened runtime** — required for notarization
- **Sparkle for updates** — standard for non-App Store Mac apps
- **XcodeGen** — `project.yml` is the source of truth; `.xcodeproj` is generated
- **Titles + tags on ScreenshotItem** — `title: String?` auto-populated from capture context, `tags: [String]` user-defined. Both backward-compatible via `decodeIfPresent` in custom `init(from:)`

---

## Completed Work

### Screen Capture Fix (P1 — Critical)

The core capture problem was not a code bug but a code signing issue. Ad-hoc signing gives every debug build a new identity, so macOS Sequoia TCC never recognizes the app.

**What was done**:
- Added `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE: Automatic` to `project.yml`
- Split `CODE_SIGN_IDENTITY` by config: Debug uses `Apple Development`, Release uses `Developer ID Application`
- Documented CGWindowListCreateImage deprecation (macOS 15) in `ScreenCaptureManager.swift`
- CG and screencapture CLI fallbacks retained for macOS 14 graceful degradation

### HistoryView Performance Fix (P2)

- **Thumbnail downsampling**: Replaced `NSImage(contentsOf:)` with `CGImageSourceCreateThumbnailAtIndex` at 320px max. Reduces per-thumbnail memory from ~30-60 MB to ~400 KB.
- **Tap gesture fix**: Reordered `.onTapGesture(count: 2)` before `.onTapGesture` to eliminate ~300ms gesture ambiguity delay.

### SCK Permission Re-check (P3)

Added `applicationDidBecomeActive` to `AppDelegate` that calls `ScreenCaptureManager.shared.checkSCKAccess()`. Newly granted permissions are detected without requiring app restart.

### Sparkle & Update System

- `UpdateManager` rewritten as singleton with auto-starting updater
- `canCheckForUpdates` bound via Combine publisher
- "Check for Updates..." added to menu bar (History & Settings section)
- Gracefully handles missing `SUFeedURL` (button stays disabled)

### Release Pipeline

- `scripts/release.sh` — one-command build: archive → Developer ID export → notarize → staple → zip
- `scripts/ExportOptions.plist` — configures `developer-id` export method

### Phase 8: Testing & UI (61 Tests)

9 bug fixes, 11 UI polish items, 2 medium-effort features (annotation undo/redo, pinned window toolbar). Test suite expanded from 13 to 61 cases across 9 files. See [HANDOFF.md](HANDOFF.md) for details.

### CG Capture Fallback

Three-tier fallback chain (SCK → screencapture CLI → CoreGraphics) with `CaptureWindow` abstraction. See [HANDOFF-CG-CAPTURE.md](HANDOFF-CG-CAPTURE.md) for details.

### Titles + Tags (Product Identity)

Added `title: String?` and `tags: [String]` to `ScreenshotItem` with backward-compatible Codable decoding. Titles auto-populate from window title or app name. Tags are user-defined strings. HistoryView displays title as primary label, supports inline title editing, tag chips with add/remove, and tag search.

### Persistence Bug Fix + Tag Normalization

Post-review hardening: `saveHistory()` was `private` and only called from `addScreenshot()` / `clearHistory()`. Title edits, tag add/remove, OCR background updates, and context menu deletes mutated `@Published` state but never persisted to UserDefaults — changes lost on restart. Fix: made `saveHistory()` internal and called it after every mutation in `HistoryView` and `CapturePipeline`. Also added case-insensitive tag deduplication (preserves display case, rejects case-only duplicates). Added 5 data integrity tests covering Codable round-trip with title/tags and mutation persistence.

### Test Target Signing Fix

`CalouraTests` target in `project.yml` was missing `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE`, causing a Team ID mismatch at test bundle load time (`dlopen` refused to load the test bundle into the host app process). Added `DEVELOPMENT_TEAM: NG4ML6Q47T` and `CODE_SIGN_STYLE: Automatic` to the test target settings, matching the app target. Regenerated `.xcodeproj` via XcodeGen. 66 tests now run from CLI (`xcodebuild test`).

### ScreenshotItem Hashable Fix

`ScreenshotItem` used synthesized `Equatable`/`Hashable` which compared all stored properties. `testHashable_sameIDsAreEqual` created two items with the same UUID but separate `Date()` calls, so the timestamps differed and the equality check failed. Fix: added explicit `==` and `hash(into:)` that use only `id`, matching the `Identifiable` semantics the rest of the codebase relies on. 66 tests pass, 0 failures.

### Private Selector Fix

Replaced undocumented `showSettingsWindow:` selector with `PreferencesWindowController` — a manual window controller following the same pattern as `HistoryWindowController`. Removed `Settings` scene from `CalouraApp.body`.

### Overlay Memory Leak Fix

Removed `isReleasedWhenClosed = false` from `CaptureOverlayWindow` and `OnboardingWindowController`. Windows are created fresh each capture and never reused, so AppKit's default release-on-close behavior is correct. `PinnedScreenshotWindow` intentionally retains `false` since pinned panels are long-lived.

### Rebrand: SnapNote → Caloura

Full product rebrand across the entire codebase. No functional changes — pure identity replacement.

**What changed**:
- **Filesystem**: `SnapNote/` → `Caloura/`, `SnapNoteTests/` → `CalouraTests/`, `SnapNoteApp.swift` → `CalouraApp.swift`, `SnapNote.entitlements` → `Caloura.entitlements`, repo root `/Users/b/SnapNote` → `/Users/b/Caloura`
- **Build config**: `project.yml` and `Info.plist` — project name, bundle IDs (`com.caloura.app`, `com.caloura.app.tests`), target names, entitlements path, usage description
- **Swift source** (13 files): App struct (`CalouraApp`), logger subsystems (`com.caloura.app`), URL scheme (`caloura://`), temp file prefix (`caloura-`), default save directory (`~/Pictures/Caloura`), filename prefix (`Caloura_`), all window titles, alert text, UI strings
- **Tests** (9 files): `@testable import Caloura`, URL scheme test URLs (`caloura://`), filename assertions (`Caloura_`), temp dir names (`CalouraTest_`), fixture strings (`main.swift - Caloura`, `Caloura.xcodeproj`)
- **Scripts**: `release.sh` — `APP_NAME`, `SCHEME`, keychain profile (`Caloura-Notarize`), appcast repo (`caloura-appcast`), all comments
- **Documentation**: `plan.md`, `ROADMAP.md`, `HANDOFF.md`, `HANDOFF-CG-CAPTURE.md`

**What did NOT change**: UserDefaults keys, notification names, Team ID, entitlements content, ExportOptions.plist content.

**Verification**: `xcodegen` succeeded, `xcodebuild build` succeeded, 66 tests pass (0 failures), `grep -ri "snapnote"` returns zero matches.

**Manual follow-up required**:
- Re-create notarization credentials: `xcrun notarytool store-credentials "Caloura-Notarize" ...`
- Re-grant TCC screen recording permission in System Settings
- Replace placeholder icons with Caloura-branded artwork
- Register `caloura.app` domain
- Create `caloura-appcast` GitHub repo
- Update Gumroad product page
- Update git remote if repo name changes on GitHub

---

## Release Pipeline

### First-Time Setup (Before First Release)

| Step | Action | Status |
|------|--------|--------|
| 1 | Create Developer ID Application certificate at developer.apple.com | **Required** |
| 2 | Store notarization credentials: `xcrun notarytool store-credentials "Caloura-Notarize" --apple-id <email> --team-id NG4ML6Q47T --password <app-specific-password>` | **Required** |
| 3 | Generate Sparkle EdDSA key: download Sparkle release, run `./bin/generate_keys`, add public key to `project.yml` as `SUPublicEDKey` | Required for auto-updates |
| 4 | Create appcast repo (e.g. GitHub Pages), add URL to `project.yml` as `SUFeedURL` | Required for auto-updates |

### Release Process

```bash
./scripts/release.sh 1.0.0
# Produces: build/Caloura-1.0.0.zip
# Upload to Gumroad
```

### Distribution Flow

```
Developer                          User
─────────                          ────
release.sh → zip                   Gumroad → download zip
           → notarize              unzip → Caloura.app
           → upload to Gumroad     macOS verifies notarization ✓
           → update appcast        Sparkle checks appcast for updates
```

---

## Open Tasks

### Priority 1 — Ship Blockers

| Task | Details | Acceptance Criteria |
|------|---------|-------------------|
| Create Developer ID certificate | developer.apple.com → Certificates | Certificate installed in Keychain |
| Store notarization credentials | `xcrun notarytool store-credentials` | `release.sh` completes notarization step |
| Run `release.sh` end-to-end | Build, sign, notarize, staple, zip | Zip opens on a clean Mac without Gatekeeper warnings |
| Set up Gumroad product page | Upload zip, set pricing (free or pay-what-you-want for education) | Download link works |

### Priority 2 — Auto-Updates

| Task | Details | Acceptance Criteria |
|------|---------|-------------------|
| Generate Sparkle EdDSA key | `./bin/generate_keys` from Sparkle release | Public key in `project.yml` `SUPublicEDKey` |
| Create appcast hosting | GitHub Pages repo | Appcast XML accessible at public URL |
| Add `SUFeedURL` to `project.yml` | Under `info.properties` | Sparkle checks for updates on launch |
| Test update flow | Publish v1.0.0, then v1.0.1 | App detects and installs update |

### Priority 3 — Code Quality

| Task | Details |
|------|---------|
| Extract `ScreenCapturing` protocol | Enable `CapturePipelineTests` (~12 cases) |
| Extract `ClipboardWriting` protocol | Enable `ClipboardManagerTests` (~5 cases) |
| Remove CG fallback methods | When deployment target moves to macOS 15.0+ |

---

## Known Issues

| Issue | Severity | Notes |
|-------|----------|-------|
| No delayed capture cancellation | Low | Once a countdown starts, it cannot be aborted |
| CGWindowListCreateImage deprecation warnings | Info | Expected — retained for macOS 14 fallback, documented in code |

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
| Keep macOS 14.0 minimum for v1, drop in v2 | Education IT lags 12-18 months on OS upgrades; CG fallback code is isolated and causes no maintenance burden; plan to drop in v2 (late 2026/early 2027) when macOS 14 is two versions behind |
| Case-insensitive tag dedup, preserve display case | Store tag as-entered ("CS101"), deduplicate by lowercased comparison. Avoids silent accumulation of case variants while preserving user's preferred casing. Search already lowercases both sides. |
| Rebrand SnapNote → Caloura | Product identity change before public launch. Done as a single atomic pass across all files — no incremental migration needed since no users exist yet. UserDefaults keys left generic (no brand in key names) to avoid data migration. |
