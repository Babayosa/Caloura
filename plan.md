# Caloura — Project Plan

## Change Log

| Date | Change |
|------|--------|
| 2026-02-02 | Full plan rewrite. Marked M3 complete. Updated to 35 source / 9 test files, 15 commits. Tightened scope to M1/M2 critical path. Added distribution coupling risk. |
| 2026-02-02 | Redesigned menu bar as native NSMenu (`.menu` style) with Shottr-inspired layout and "More" submenu. Overhauled area capture UX: dot cursor, no dimming, first-click starts drag. Added custom app icon (10 sizes) and menu bar template icon (3 scales). Ran full audit; fixed force unwrap, removed dead code, added error logging. 18 commits. Backlog items 1–2 complete. |
| 2026-02-02 | Generated Sparkle EdDSA keypair, embedded SUPublicEDKey. Installed Developer ID Application cert. Stored notarization credentials. Ran `release.sh` end-to-end — v1.0.0 notarized and stapled (3.3 MB). Fixed signing config (manual for Release). M1 complete. 21 commits. Backlog items 3–7 (partial) done. |
| 2026-02-02 | Purchased `caloura.app` domain (Squarespace). Created `Babayosa/caloura-site` GitHub repo with Pages enabled. Landing page live at https://caloura.app. Added `SUFeedURL` to Info.plist. Backlog items 7–8 done. 22 commits. |

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

**Status**: Feature-complete. Signed, notarized, distributable build exists (`build/Caloura-1.0.0.zip`, 3.3 MB). Landing page live at https://caloura.app. Sparkle fully configured (`SUPublicEDKey` + `SUFeedURL`). Missing: Gumroad page, appcast.xml, Sparkle upgrade test, download link wiring.

**Codebase**: 35 source files, 9 test files (66 tests, 0 failures). macOS 14.0+, Swift 5.9, XcodeGen (`project.yml`). Dependencies: KeyboardShortcuts 2.0+, Sparkle 2.5+. 22 commits on `main`.

**What works**:
- 3 capture modes (area, window, fullscreen) + repeat + delayed (with countdown overlay + ESC cancel) + multi-display
- 3-tier capture backend: SCK → screencapture CLI → CoreGraphics (deprecated fallback)
- Smart crop (Vision saliency + border trim), background OCR, PNG/JPEG/TIFF export
- Clipboard: image / markdown / citation / multi-format. File save: `~/Pictures/Caloura/YYYY-MM-DD/`
- Native NSMenu menu bar with "More" submenu, dot cursor for area capture (no dimming), onboarding (4-step with permission polling), preferences (4 tabs), searchable history (tags, thumbnails, 50-item cap)
- Annotation (arrow/rect/highlight + undo), pinned windows (with dedup), Quick Access overlay (5 actions, 8s auto-dismiss)
- URL scheme (10 routes), context detection (6 app categories), 7 customizable hotkeys
- Launch at Login (SMAppService)
- 66 tests, 0 failures (9 of 35 source files covered; core modules like ScreenCaptureManager untested)

**What's missing for v1**:
- ~~App icon asset catalog~~ ✅ Custom icon, 10 sizes (commit `a5a3231`)
- ~~Menu bar icon~~ ✅ Custom template icon, 3 scales (commit `a5a3231`)
- ~~Sparkle EdDSA key~~ ✅ `SUPublicEDKey` embedded (commit `e8bc0fd`). ~~`SUFeedURL`~~ ✅ set to `https://caloura.app/appcast.xml` (commit `2cee30e`)
- ~~`release.sh`~~ ✅ Full pipeline tested: archive → sign → notarize → staple → zip (commit `e8bc0fd`)
- ~~Developer ID cert~~ ✅ Installed + notarization credentials stored as `Caloura-Notarize`
- ~~Landing page~~ ✅ Live at https://caloura.app (GitHub Pages + custom domain)
- No Gumroad page yet
- README screenshot placeholder unfilled

---

## D. Target v1 Scope (Must-Ship)

1. ~~App icon (10 sizes) + menu bar template icon (@1x, @2x, @3x)~~ ✅ Done
2. ~~Apple Developer account provisioned, Developer ID cert installed~~ ✅ Done
3. ~~Notarization credentials stored (`Caloura-Notarize` keychain profile)~~ ✅ Done
4. ~~`release.sh` end-to-end success → notarized + stapled `.zip`~~ ✅ Done (v1.0.0, 3.3 MB)
5. ~~Sparkle EdDSA keypair generated, `SUPublicEDKey` + `SUFeedURL`~~ ✅ Done
6. ~~Landing page live at `caloura.app`~~ ✅ Done (GitHub Pages, custom domain, HTTPS)
7. Gumroad product page with working download
8. Sparkle upgrade rehearsal: v1.0.0 → v1.0.1 on clean Mac
9. Clean-machine verification: unzip → launch → no Gatekeeper warning → capture works
10. Permissions troubleshooting section on landing page
11. Appcast + update signing pipeline: repeatable process to sign releases and generate appcast entries

_M1 complete. Landing page + Sparkle config done. Remaining: Gumroad, appcast.xml, Sparkle upgrade test, clean-machine verification._

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

### M1: Distributable Build ✅ Complete
~~Design icons. Provision Developer ID cert. Store notarization credentials. Run `release.sh` end-to-end.~~
All items shipped. Notarized v1.0.0 build at `build/Caloura-1.0.0.zip` (3.3 MB). Signature valid, staple verified. Clean-machine Gatekeeper test pending (M2 item 9).
**Done means**: `codesign -vv Caloura.app` shows valid Developer ID ✅. `xcrun stapler validate` passes ✅.

### M2: Distribution Live ← **Current**
~~Landing page at `caloura.app`~~ ✅. ~~Sparkle EdDSA key + SUFeedURL~~ ✅. Remaining: Gumroad product page, appcast.xml, Sparkle upgrade test, download link wiring, clean-machine verification.
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
| 1 | ~~Design + export app icon (10 sizes)~~ | M1 | ✅ Done (commit `a5a3231`) |
| 2 | ~~Design + export menu bar template icon~~ | M1 | ✅ Done (commit `a5a3231`) |
| 3 | ~~Provision Apple Developer account + cert~~ | M1 | ✅ Done — Developer ID Application cert installed |
| 4 | ~~Store notarization credentials~~ | M1 | ✅ Done — `Caloura-Notarize` keychain profile |
| 5 | ~~Run `release.sh` end-to-end, fix issues~~ | M1 | ✅ Done — v1.0.0 notarized + stapled (3.3 MB). Fixed manual signing for Release. |
| 6 | ~~Generate Sparkle EdDSA keypair~~ | M2 | ✅ Done — private key in Keychain, public key in Info.plist |
| 7 | ~~Add `SUFeedURL` to project.yml~~ | M2 | ✅ Done — `https://caloura.app/appcast.xml` (commit `2cee30e`) |
| 8 | ~~Build landing page (`caloura.app`)~~ | M2 | ✅ Done — GitHub Pages, Squarespace DNS, HTTPS enforced. Repo: `Babayosa/caloura-site` |
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
| 2 | ~~`release.sh` never run~~ | ~~Unknown signing/notarization failures~~ | ✅ Mitigated — ran successfully. Fixed manual signing for Release config. |
| 3 | Sparkle update flow untested | Silent failure on first update push | Test full v1.0.0 → v1.0.1 cycle before public launch (M2 exit criterion). |
| 4 | ~~Distribution coupling~~ | ~~Sparkle needs stable appcast hosting~~ | ✅ Mitigated — `caloura.app` (GitHub Pages) is single source of truth for appcast.xml + downloads. Gumroad is checkout only. |
| 5 | `CGWindowList*` removal in future macOS | CG fallback + context detection break | ScreenCaptureManager: isolated behind `sckFailed` flag. ContextDetector: also uses `CGWindowListCopyWindowInfo` for active-window titles (NOT behind `sckFailed`). Both need migration when target moves to 15.0+. |
| 6 | Sparkle EdDSA key loss | Existing installs can't verify updates → stranded users | Generate once, back up private key immediately. Public key baked into Info.plist is permanent. |
| 7 | CFBundleVersion / CFBundleShortVersionString mismatch | Sparkle skips updates or triggers downgrades | release.sh already sets both; verify format matches Sparkle expectations (semver for short, integer for build). |
| 8 | Notarization credential brittleness | "Works on my machine" failures across machines or CI | Keychain profile (Caloura-Notarize) is machine-local. Document setup steps; test on clean account before adding CI. |

---

## I. Open Questions

1. ~~**App icon**: Hire designer or DIY?~~ Resolved — custom icons generated and integrated.
2. **Pricing**: What's the non-edu price? ($15 / $19 / pay-what-you-want?)
3. ~~**Landing page tech**~~ Resolved — static HTML + CSS on GitHub Pages (`Babayosa/caloura-site`), custom domain `caloura.app` via Squarespace DNS.
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

Verified: macOS 15.2 / Xcode 16 / Apple Silicon. Release pipeline tested (v1.0.0 notarized). macOS 14.x validation pending (see backlog).

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
| Native NSMenu (`.menu` style) for menu bar | Shottr-style clean dropdown; right-aligned shortcuts rendered by AppKit; "More" submenu for secondary actions |
| Dot cursor instead of crosshair for area capture | Differentiate from Shottr's crosshair; no preference toggle (YAGNI) |
| No screen dimming during area capture | User wants full clarity to see exactly what they're capturing |
| Custom icons, not generated | User designed icons externally and provided source PNGs; resized via Pillow |
| Manual signing for Release builds | Automatic signing only works with Apple Development certs; Developer ID requires `CODE_SIGN_STYLE: Manual` |
| GitHub Pages for hosting | Static HTML + appcast.xml at `caloura.app`. Squarespace as registrar, DNS points to GitHub. Simple, free, reliable. |
| `caloura.app` domain | Clean, short, `.app` enforces HTTPS. Purchased via Squarespace. |
