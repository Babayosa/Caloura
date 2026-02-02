# Caloura — Project Plan

## Change Log

| Date | Change |
|------|--------|
| 2026-02-02 | Full plan rewrite. Marked M3 complete. Updated to 35 source / 9 test files, 15 commits. Tightened scope to M1/M2 critical path. Added distribution coupling risk. |

---

## A. Product Definition

Caloura is a macOS menu-bar screenshot tool for knowledge workers. It captures regions, windows, and full screens with smart cropping, OCR, annotation, presets, and multi-format clipboard output — all from a lightweight menu-bar icon. Distribution is direct download (Gumroad) for faster iteration, Sparkle auto-updates, and fewer MAS constraints; app requires Screen Recording permission. Competitive edge: one-time purchase, no subscription.

---

## B. Non-Goals (v1)

- Screen recording / video capture
- Scrolling capture
- Cloud upload / sharing service
- Custom user-created presets (4 built-in only)
- iOS or iPad support
- App Store distribution
- Background/backdrop styling tools
- Accessibility (VoiceOver) beyond basic labels
- Localization / internationalization
- Free .edu tier (deferred to M4)

---

## C. Current Reality

**Status**: Feature-complete. Not shippable (missing icons, signing, and distribution infrastructure).

**Codebase**: 35 source files (5,303 lines), 9 test files (1,088 lines). macOS 14.0+, Swift 5.9, XcodeGen (`project.yml`). Dependencies: KeyboardShortcuts 2.0+, Sparkle 2.5+. 15 commits on `main`.

**What works**:
- 3 capture modes (area, window, fullscreen) + repeat + delayed (with countdown overlay + ESC cancel) + multi-display
- 3-tier capture backend: SCK → screencapture CLI → CoreGraphics (deprecated fallback)
- Smart crop (Vision saliency + border trim), background OCR, PNG/JPEG/TIFF export
- Clipboard: image / markdown / citation / multi-format. File save: `~/Pictures/Caloura/YYYY-MM-DD/`
- Menu bar UI, onboarding (4-step with permission polling), preferences (4 tabs), searchable history (tags, thumbnails, 50-item cap)
- Annotation (arrow/rect/highlight + undo), pinned windows (with dedup), Quick Access overlay (5 actions, 8s auto-dismiss)
- URL scheme (10 routes), context detection (6 app categories), 7 customizable hotkeys
- Launch at Login (SMAppService)
- 66 tests, 0 failures (9 of 35 source files covered; core modules like ScreenCaptureManager untested)

**What's missing for v1**:
- App icon asset catalog: **placeholder JSON only, no PNGs**
- Menu bar icon: **SF Symbol fallback** (`camera.viewfinder`)
- Sparkle: framework integrated, `UpdateManager` wired, but **no EdDSA key, no `SUPublicEDKey`, no `SUFeedURL`** in Info.plist
- `scripts/release.sh` (138 lines): complete pipeline (archive → export → notarize → staple → zip) but **never run** — no Developer ID cert
- No landing page, no Gumroad page
- README screenshot placeholder unfilled

---

## D. Target v1 Scope (Must-Ship)

1. App icon (10 sizes) + menu bar template icon (@1x, @2x)
2. Apple Developer account provisioned, Developer ID cert installed
3. Notarization credentials stored (`Caloura-Notarize` keychain profile)
4. `release.sh` end-to-end success → notarized + stapled `.zip`
5. Sparkle EdDSA keypair generated, `SUPublicEDKey` + `SUFeedURL` in Info.plist
6. Landing page live at `caloura.app` (download link + appcast.xml hosted)
7. Gumroad product page with working download
8. Sparkle upgrade rehearsal: v1.0.0 → v1.0.1 on clean Mac
9. Clean-machine verification: unzip → launch → no Gatekeeper warning → capture works
10. Permissions troubleshooting section on landing page
11. Appcast + update signing pipeline: repeatable process to sign releases and generate appcast entries

_Launch at Login and README shipped. Screenshot placeholder remains._

---

## E. Architecture Snapshot

```
HotKey / Menu / URL Scheme
  → CapturePipeline (singleton, @MainActor)
      → ScreenCaptureManager
          → SCK (primary, .best resolution)
          → screencapture CLI (fallback)
          → CoreGraphics (last resort, legacy — may break in future macOS)
      → ImageProcessor (optional SmartCropper via Vision)
      → FileOrganizer (~/Pictures/Caloura/YYYY-MM-DD/)
      → ClipboardManager (image / markdown / citation / multi-format)
      → QuickAccessOverlay (5 actions, 8s auto-dismiss)
      → CountdownOverlay (ESC-cancellable delayed capture)
      → OCREngine (background, matches by UUID)
```

| Dir | Purpose | Key files |
|-----|---------|-----------|
| `App/` | Entry point, pipeline, updates, URL scheme | `CalouraApp.swift`, `CapturePipeline.swift` |
| `Capture/` | Backends, overlays, selection views | `ScreenCaptureManager.swift` (557 lines, largest file) |
| `Processing/` | Crop, OCR, format encoding | `SmartCropper.swift`, `OCREngine.swift` |
| `Distribution/` | Clipboard, file org, markdown | `ClipboardManager.swift`, `FileOrganizer.swift` |
| `Context/` | Presets, app category detection | `PresetManager.swift`, `ContextDetector.swift` |
| `Models/` | State, settings, data structs | `AppState.swift`, `AppSettings.swift` |
| `UI/` | All views and window controllers | `MenuBarView.swift`, `PreferencesView.swift`, `CountdownOverlay.swift` |
| `HotKeys/` | Keyboard shortcut registration | `HotKeyManager.swift` |

**Storage**: UserDefaults only (history JSON ≤50 items, settings). No database.

**Signing**: Debug = Apple Development, Release = Developer ID Application. Team `NG4ML6Q47T`. Hardened runtime, no sandbox. Entitlement: `com.apple.security.app-sandbox = false`.

---

## F. Milestones

### M1: Distributable Build
Design icons. Provision Developer ID cert. Store notarization credentials. Run `release.sh` end-to-end.
**Done means**: `codesign -vv Caloura.app` shows valid Developer ID. `xcrun stapler validate` passes. Zip opens on clean Mac with no Gatekeeper warning.

### M2: Distribution Live
Landing page at `caloura.app` hosting appcast.xml + download binaries (source of truth). Gumroad as checkout/fulfillment (links to caloura.app/download). Sparkle EdDSA key embedded.
**Done means**: User can discover, download, install, auto-update. Sparkle upgrade cycle tested (v1.0.0 → v1.0.1) on clean Mac. Appcast signing pipeline documented and repeatable.

### M3: Post-Launch Polish ✅ Complete
~~Launch at Login. Delayed capture cancellation (ESC / menu). Countdown overlay. Pinned screenshot dedup.~~
All 4 items shipped: commits `1c3109e`, `6975221`, `d03cf78`.

### M4: Growth
Raycast extension. Homebrew cask. GitHub Actions CI. `.edu` pricing flow.
**Done means**: Two additional distribution channels live. CI green on every push.

---

## G. Backlog (Prioritized)

| # | Item | Milestone | Status |
|---|------|-----------|--------|
| 1 | Design + export app icon (10 sizes) | M1 | Asset catalog ready, needs PNGs |
| 2 | Design + export menu bar template icon | M1 | Monochrome, @1x + @2x |
| 3 | Provision Apple Developer account + cert | M1 | $99/yr, Developer ID Application |
| 4 | Store notarization credentials | M1 | `xcrun notarytool store-credentials` |
| 5 | Run `release.sh` end-to-end, fix issues | M1 | Script exists (138 lines), never tested |
| 6 | Generate Sparkle EdDSA keypair | M2 | `sparkle/bin/generate_keys` |
| 7 | Add `SUPublicEDKey` + `SUFeedURL` to project.yml | M2 | Absent from Info.plist. Until added, UpdateManager.canCheckForUpdates stays false silently |
| 8 | Build landing page (`caloura.app`) | M2 | Source of truth for appcast.xml + binaries. Gumroad links here. Include permissions troubleshooting |
| 9 | Create Gumroad product page | M2 | |
| 10 | Test Sparkle upgrade cycle (v1.0.0 → v1.0.1) | M2 | Full cycle on clean Mac |
| 11 | Appcast + update signing pipeline | M2 | `generate_appcast` after each release; document in release.sh |
| 12 | macOS 14.x clean-machine validation | M2 | VM or physical Sonoma machine; current "Verified" is 15.2 only |
| 13 | Add README screenshot | M2 | Placeholder exists (`<!-- TODO -->`) |
| 14 | Raycast extension (wraps URL scheme) | M4 | Zero maintenance |
| 15 | Homebrew cask submission | M4 | After stable download URL |
| 16 | GitHub Actions CI | M4 | `xcodegen generate && xcodebuild test` |
| 17 | `.edu` pricing flow in Gumroad | M4 | Coupon or separate product |

---

## H. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|------|--------|------------|
| 1 | Screen Recording permission UX on Sequoia worse than Sonoma | Users fail to grant → app unusable | Two-state alert + onboarding polling. screencapture CLI may work without grant on some versions but not guaranteed. Troubleshooting in README (done) and landing page (M2). |
| 2 | `release.sh` never run | Unknown signing/notarization failures | Run early in M1. Budget debugging time for entitlements + provisioning. |
| 3 | Sparkle update flow untested | Silent failure on first update push | Test full v1.0.0 → v1.0.1 cycle before public launch (M2 exit criterion). |
| 4 | Distribution coupling | Sparkle needs stable appcast hosting; Gumroad URL must not break update checks | Choose single source of truth for download URLs early in M2. |
| 5 | `CGWindowList*` removal in future macOS | CG fallback + context detection break | ScreenCaptureManager: isolated behind `sckFailed` flag. ContextDetector: also uses `CGWindowListCopyWindowInfo` for active-window titles (NOT behind `sckFailed`). Both need migration when target moves to 15.0+. |
| 6 | Sparkle EdDSA key loss | Existing installs can't verify updates → stranded users | Generate once, back up private key immediately. Public key baked into Info.plist is permanent. |
| 7 | CFBundleVersion / CFBundleShortVersionString mismatch | Sparkle skips updates or triggers downgrades | release.sh already sets both; verify format matches Sparkle expectations (semver for short, integer for build). |
| 8 | Notarization credential brittleness | "Works on my machine" failures across machines or CI | Keychain profile (Caloura-Notarize) is machine-local. Document setup steps; test on clean account before adding CI. |

---

## I. Open Questions

1. **App icon**: Hire designer or DIY? Visual style? (Camera lens / viewfinder / abstract?)
2. **Pricing**: What's the non-edu price? ($15 / $19 / pay-what-you-want?)
3. **Landing page tech**: Static HTML, Framer, Hugo? Hosting? (caloura.app domain assumed available.)
4. **macOS 15 minimum**: Should v1.1 drop macOS 14 and remove CG fallback? Depends on target user IT timelines.
5. **History persistence**: 50-item UserDefaults cap. Migrate to SQLite in v1.1 if "searchable history" is a selling point?
6. **macOS 14 validation**: Do we have access to a Sonoma machine or VM for clean-machine testing?

---

## J. How to Run

```bash
# Generate Xcode project (required after adding/removing files)
xcodegen generate

# Build
xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug

# Test (66 tests)
xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug

# Open in Xcode
open Caloura.xcodeproj

# Release build (requires Developer ID cert + notarization credentials)
./scripts/release.sh 1.0.0
```

Verified: macOS 15.2 / Xcode 16 / Apple Silicon. macOS 14.x validation pending (see backlog).

---

## K. Decisions Log

| Decision | Rationale |
|----------|-----------|
| Gumroad, not App Store | Faster iteration, Sparkle auto-updates, fewer MAS constraints (not a technical impossibility) |
| Sparkle for auto-updates | Industry standard for direct-distribution Mac apps |
| macOS 14.0 minimum | Education IT lags 12–18 months; CG fallback is isolated |
| 4 built-in presets only (v1) | Custom presets are scope creep; built-ins cover core workflows |
| UserDefaults for history (50 items) | ~50–100 KB; adequate for v1; consider SQLite if limits grow |
| Capture sound off by default | User preference; toggle in Preferences |
| Keep CG fallback code | Graceful degradation on macOS 14; remove when target is 15.0+ |
| ID-only equality on ScreenshotItem | Supports mutable title/tags without breaking SwiftUI identity |
| No sandbox | Required for screen capture, file I/O to arbitrary paths, system integration |
| caloura.app hosts binaries | Source of truth for appcast.xml + downloads. Gumroad is checkout only. Eliminates URL-change risk for Sparkle. |
| .edu pricing deferred to M4 | Don't market what doesn't exist. Re-add to product definition when flow ships. |
