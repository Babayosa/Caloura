# Caloura — Project Plan

## Change Log

| Date | Change |
|------|--------|
| 2026-02-02 | Full rewrite. Removed stale completed-work log, verbose known-issues table, and duplicated ROADMAP content. Aligned with actual codebase (66 tests, 9 commits). Added milestones, risks, open questions. |

---

## A. Product Definition

Caloura is a macOS menu-bar screenshot tool for students, educators, and knowledge workers. It captures regions, windows, and full screens with smart cropping, OCR, annotation, presets, and multi-format clipboard output — all from a lightweight menu-bar icon. Distribution is direct download (Gumroad) for faster iteration, Sparkle auto-updates, and fewer MAS constraints; app requires Screen Recording permission. Competitive edge: free for `.edu`, one-time purchase for everyone else, no subscription.

---

## B. Non-Goals (v1)

- Screen recording / video capture
- Scrolling capture
- Cloud upload / sharing service
- Custom user-created presets (4 built-in only)
- iOS or iPad support
- App Store distribution
- Background/backdrop styling tools

---

## C. Current Reality

**Status**: Feature-complete. Not shippable.

- macOS 14.0+, Swift 5.9, XcodeGen (`project.yml`), KeyboardShortcuts + Sparkle deps
- 3 capture modes (area, window, fullscreen) + repeat + delayed + multi-display selector
- 3-tier capture backend: SCK → screencapture CLI → CoreGraphics (deprecated fallback)
- Processing: smart crop (Vision saliency + border trim), background OCR, PNG/JPEG/TIFF export
- Distribution: clipboard (image / markdown / citation / multi-format), organized file save, Quick Access overlay
- UI: menu bar, onboarding (4-step with permission polling), preferences (4 tabs), history (searchable, tags, thumbnails), annotation (arrow/rect/highlight + undo), pinned windows
- Automation: URL scheme (11 routes), context detection (6 app categories), 7 hotkeys (customizable)
- Sparkle integrated but unconfigured (no EdDSA key, no feed URL)
- 66 tests across 9 files, 0 failures
- App icon asset catalog exists but **contains no images** (placeholder JSON only)
- Menu bar icon slot empty (code uses SF Symbol `camera.viewfinder` fallback)
- `release.sh` exists (archive → export → notarize → staple → zip) but **never run** (no Developer ID cert)
- 9 commits on `main`, last: `ff29c0e` (2026-02-02)

---

## D. Target v1 Scope (Must-Ship)

1. App icon (10 sizes) + menu bar template icon (2 sizes)
2. Apple Developer account provisioned, Developer ID cert installed
3. Notarization credentials stored (`Caloura-Notarize` keychain profile)
4. `release.sh` end-to-end success → notarized + stapled `.zip`
5. Sparkle EdDSA keypair generated, public key in Info.plist
6. Landing page live at `caloura.app` (download link + appcast.xml)
7. Gumroad product page with working download
8. Clean-machine verification: unzip → launch → no Gatekeeper warning → capture works
9. "Launch at Login" preference toggle
10. README with install instructions + screenshot
11. Permissions troubleshooting section in README + landing page
12. Sparkle upgrade rehearsal: v1.0.0 → v1.0.1 on clean Mac before public launch

---

## E. Architecture Snapshot

```
HotKey / Menu / URL Scheme
  → CapturePipeline (singleton, @MainActor)
      → ScreenCaptureManager
          → SCK (primary, .best resolution)
          → screencapture CLI (fallback, system binary entitlements)
          → CoreGraphics (last resort, deprecated macOS 15)
      → ImageProcessor (optional SmartCropper via Vision)
      → FileOrganizer (~/Pictures/Caloura/YYYY-MM-DD/)
      → ClipboardManager (image / markdown / citation / multi-format)
      → QuickAccessOverlay (5 actions, 8s auto-dismiss)
      → OCREngine (background, matches by UUID)
```

**Key modules** (all under `Caloura/`):

| Dir | Purpose | Key files |
|-----|---------|-----------|
| `App/` | Entry point, pipeline, updates, URL scheme | `CalouraApp.swift`, `CapturePipeline.swift` |
| `Capture/` | Backends, overlays, selection views | `ScreenCaptureManager.swift`, `*SelectionView.swift` |
| `Processing/` | Crop, OCR, format encoding | `SmartCropper.swift`, `OCREngine.swift` |
| `Distribution/` | Clipboard, file org, markdown | `ClipboardManager.swift`, `FileOrganizer.swift` |
| `Context/` | Presets, app category detection | `PresetManager.swift`, `ContextDetector.swift` |
| `Models/` | State, settings, data structs | `AppState.swift`, `AppSettings.swift` |
| `UI/` | All views and window controllers | `MenuBarView.swift`, `PreferencesView.swift` |
| `HotKeys/` | Keyboard shortcut registration | `HotKeyManager.swift` |

**Storage**: UserDefaults only (history JSON ≤50 items, settings, presets). No database.

**Signing**: Debug = Apple Development, Release = Developer ID Application. Team `NG4ML6Q47T`. Hardened runtime, no sandbox.

---

## F. Milestones

### M1: Distributable Build
Design app icon + menu bar icon. Provision Developer ID cert. Store notarization credentials. Run `release.sh` end-to-end.
**Done means**: `codesign -vv Caloura.app` shows valid Developer ID. `xcrun stapler validate` passes. Zip opens on clean Mac with no Gatekeeper warning.

### M2: Distribution Live
Landing page at `caloura.app` with download link. Gumroad product page. Sparkle EdDSA key embedded, appcast.xml hosted.
**Done means**: User can discover, download, install, auto-update. Sparkle upgrade cycle tested (v1.0.0 → v1.0.1) on clean Mac.

### M3: Post-Launch Polish (v1.1)
Launch at Login toggle. Delayed capture cancellation (ESC / menu button). Countdown overlay. Pinned screenshot dedup.
**Done means**: All P2 items resolved. No known UX papercuts.

### M4: Growth
Raycast extension. Homebrew cask. GitHub Actions CI. `.edu` pricing flow.
**Done means**: Two additional distribution channels live. CI green on every push.

---

## G. Backlog (Prioritized)

| # | Item | Milestone | Notes |
|---|------|-----------|-------|
| 1 | Design + export app icon (10 sizes) | M1 | Asset catalog ready, needs PNGs |
| 2 | Design + export menu bar template icon | M1 | Monochrome, @1x + @2x |
| 3 | Provision Apple Developer account + cert | M1 | $99/yr, Developer ID Application |
| 4 | Store notarization credentials | M1 | `xcrun notarytool store-credentials` |
| 5 | Run `release.sh` end-to-end, fix issues | M1 | Script exists, never tested |
| 6 | Generate Sparkle EdDSA keypair | M2 | `sparkle/bin/generate_keys` |
| 7 | Add `SUPublicEDKey` + `SUFeedURL` to Info.plist | M2 | Currently empty |
| 8 | Build landing page (`caloura.app`) | M2 | Host appcast.xml here too |
| 9 | Create Gumroad product page | M2 | |
| 10 | Add "Launch at Login" preference | M3 | Expected for menu-bar apps |
| 11 | Delayed capture cancellation (ESC + menu) | M3 | Known P2 issue |
| 12 | Countdown overlay for delayed captures | M3 | Floating number on screen |
| 13 | Pinned screenshot deduplication | M3 | Prevent double-pin |
| 14 | Raycast extension (wraps URL scheme) | M4 | Zero maintenance |
| 15 | Homebrew cask submission | M4 | After stable download URL |

---

## H. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|------|--------|------------|
| 1 | Screen recording permission UX on Sequoia is worse than Sonoma | Users fail to grant permission → app unusable | Two-state permission alert helps; onboarding polls for status. Screencapture CLI may work without explicit grant on some OS versions but this is not guaranteed across Sonoma/Sequoia. Must include troubleshooting guide in README and landing page. |
| 2 | `CGWindowListCreateImage` removed in future macOS | CG fallback breaks | Isolated behind `sckFailed` flag; marked for removal when deployment target moves to 15.0+ |
| 3 | `release.sh` has never been run | Unknown failures at signing/notarization time | Run early in M1; budget time for debugging entitlements + provisioning |
| 4 | Sparkle update flow untested | Silent failure on first update push | Test full cycle (v1.0.0 → v1.0.1) before public launch |
| 5 | No protocol extraction for ScreenCaptureManager / ClipboardManager | Hard to unit-test capture pipeline | Acceptable for v1 (66 tests cover utilities); extract protocols in v1.1 if test gaps cause regressions |
| 6 | Distribution coupling: Sparkle requires stable hosting for appcast + binaries; notarization pipeline (release.sh) is unproven; Gumroad download URL must not break Sparkle users | Update mechanism fails silently or downloads break | Must choose single source of truth for downloads early in M2 |

---

## I. Open Questions

1. **App icon design**: Hire a designer or DIY? What visual style? (Camera lens? Viewfinder? Abstract?)
2. **Pricing**: Free for `.edu` confirmed — what's the price for non-edu? ($15? $19? Pay-what-you-want?)
3. **Landing page**: Static HTML or a generator (e.g. Framer, simple Hugo)? Who hosts?
4. **macOS 15 minimum**: Should v1.1 drop macOS 14 support and remove CG fallback code? Depends on education IT adoption timeline.
5. **Custom presets**: Users have asked — scope for v1.1 or defer further?
6. **History limit**: 50-item cap in UserDefaults — if positioning includes "searchable history with tags," users may expect persistence. Should v1.1 migrate to SQLite?

---

## J. How to Run

```bash
# Generate Xcode project (required after adding/removing files)
cd /Users/b/Caloura
xcodegen generate

# Build (Debug)
xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug

# Run tests (66 tests)
xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug

# Open in Xcode
open Caloura.xcodeproj

# Release build (requires Developer ID cert + notarization credentials)
./scripts/release.sh 1.0.0
```

All commands verified on macOS 15.2 / Xcode 16 / Apple Silicon.

---

## K. Decisions Log

| Decision | Rationale |
|----------|-----------|
| Gumroad, not App Store | Direct distribution chosen for faster iteration, Sparkle auto-updates, and fewer MAS constraints (not a technical impossibility) |
| Sparkle for auto-updates | Industry standard for direct-distribution Mac apps |
| macOS 14.0 minimum | Education IT lags 12–18 months; CG fallback is isolated |
| 4 built-in presets only (v1) | Custom presets are scope creep; built-ins cover core workflows |
| UserDefaults for history (50 items max) | ~50–100 KB; adequate for v1; consider SQLite if limits grow |
| Capture sound off by default | User preference; toggle available in Preferences |
| Keep CG fallback code | Graceful degradation on macOS 14; remove when target is 15.0+ |
| ID-only equality on ScreenshotItem | Supports mutable title/tags without breaking SwiftUI identity |
