# Caloura Roadmap

## Where You Are

Caloura is **feature-complete for v1.0** but **not shippable**. The code compiles, all 19 tests pass, and the feature set covers Phases 1–7. What's missing is release infrastructure: icons, code signing, notarization, and a landing page.

---

## Immediate: Ship Blockers

These must be done before anyone outside of you can run the app.

### 1. App Icon & Menu Bar Icon
- `Assets.xcassets/AppIcon.appiconset/` — 10 PNG sizes needed (16–512 @1x/@2x)
- `Assets.xcassets/MenuBarIcon.imageset/` — template image (monochrome, @1x/@2x)
- The menu bar currently uses `Image(systemName: "camera.viewfinder")` in code, but the asset catalog slot is empty

### 2. Code Signing & Notarization
- Requires an Apple Developer account ($99/year)
- Set `DEVELOPMENT_TEAM` in the Xcode project
- Sign with "Developer ID Application" certificate (for direct distribution, not App Store — sandbox is disabled)
- Notarize with `xcrun notarytool` — required for Gatekeeper on macOS 10.15+
- Without this, users get "app is damaged and can't be opened"

### 3. Sparkle EdDSA Key
- `SUPublicEDKey` in Info.plist is empty
- Generate a keypair with `sparkle/bin/generate_keys`
- Embed the public key in Info.plist, keep the private key for signing updates
- Without this, auto-update is broken

### 4. Distribution Package
- Create a DMG or ZIP for download
- Host at the domain matching `SUFeedURL` (`caloura.app`)
- Create `appcast.xml` for Sparkle to check for updates

---

## Phase 8: Test Coverage

Current coverage: ~10% (4 utility classes). No tests for the core pipeline, URL scheme, or state management.

### 8A: Unit Tests for New Features
| Test | What to cover |
|------|--------------|
| `URLSchemeHandlerTests` | URL parsing, host/path routing, preset normalization, query params, unknown modes |
| `CapturePipelineTests` | `captureRepeat()` with nil rect, `captureDelayed()` countdown clamping, `isCapturing` state transitions |
| `QuickAccessOverlayTests` | Action routing (mock ClipboardManager), dismiss behavior |
| `AppStateTests` | History persistence, `@Published` reactivity, max items enforcement |

### 8B: Integration Tests
| Test | What to cover |
|------|--------------|
| URL scheme end-to-end | Register handler → receive URL → verify correct pipeline method called |
| Notification routing | Post notification → verify AppDelegate routes to correct pipeline method |
| Preset switching via URL | `?preset=lecture-notes` → verify `AppSettings.activePreset` changes |

### 8C: Snapshot/UI Tests
- Menu bar view renders all items
- Preferences tabs display correctly
- Onboarding flow completes

---

## Phase 9: Polish & UX

### 9A: Delayed Capture Cancellation
- Store the `Task` handle from `captureDelayed()` on the pipeline
- Add a "Cancel" button to the menu bar during countdown
- ESC key cancels the countdown
- Fixes the known issue of uncancellable countdowns

### 9B: Countdown Overlay
- Show a floating countdown number (3... 2... 1...) on screen during delayed capture
- Much more visible than the status message in the menu bar
- Similar to macOS's built-in screenshot countdown

### 9C: Quick Access Overlay Refinements
- Pass the `ProcessedScreenshot` through notifications for Pin/Annotate (fixes the "wrong screenshot" edge case from the handoff)
- Add hover states to buttons (currently `.plain` style with no visual feedback)
- Respect Dynamic Type for label font size (currently hardcoded 9pt)

### 9D: Pinned Screenshot Improvements
- Deduplicate: prevent pinning the same screenshot twice
- Add opacity slider or transparency toggle
- Add right-click context menu (Copy, Save As, Close)
- Show image dimensions in the window title

---

## Phase 10: Competitive Differentiators

Features from the competitive analysis that would widen the gap against Shottr and CleanShot X.

### 10A: .edu Email Auto-Discount (Pricing)
- Free for `.edu` email addresses (auto-verified, no manual email)
- $15–19 one-time for everyone else
- No subscription — biggest positioning move against CleanShot's $29+$19/yr model
- Requires: license key generation, email verification API, in-app activation flow

### 10B: Raycast Extension
- Publish a Raycast extension that wraps `caloura://` URLs
- Users search "Caloura" in Raycast → see capture commands with icons
- Zero effort to maintain — delegates to URL scheme
- Both Shottr and CleanShot have Raycast integrations; Caloura must match

### 10C: Shortcuts.app Actions
- Expose App Intents for Capture Area, Capture Fullscreen, Copy Markdown, etc.
- Goes beyond URL schemes — lets users build multi-step Shortcuts
- Requires adding AppIntents framework dependency and defining `AppIntent` structs

### 10D: Custom Presets via URL Scheme
- Currently only built-in presets are addressable via `?preset=`
- Allow `?preset=My+Research+Notes` to match user-created presets
- Search `PresetManager.shared.presets` by name with fuzzy matching

---

## Phase 11: Growth & Distribution

### 11A: Landing Page (caloura.app)
- Single-page site: hero screenshot, feature grid, download button, .edu verification
- Host `appcast.xml` for Sparkle updates
- Accurate JSON-LD schema from day one (unlike Shottr's stale schema)
- Must exist before distribution since `SUFeedURL` points to it

### 11B: Homebrew Cask
```ruby
cask "caloura" do
  version "1.0.0"
  sha256 "..."
  url "https://caloura.app/dl/Caloura-#{version}.dmg"
  name "Caloura"
  homepage "https://caloura.app"
  app "Caloura.app"
end
```
- Submit to homebrew-cask for `brew install --cask caloura`
- Easiest distribution channel for developer/student audience

### 11C: GitHub Actions CI
```yaml
on: [push, pull_request]
jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme Caloura -configuration Debug build
      - run: xcodebuild -scheme Caloura -configuration Debug test
```
- Automated build + test on every push
- Add code signing + notarization for tagged releases
- Add `xcresult` artifact upload for test reports

### 11D: Competitor Monitoring
- Set up visualping.io on `shottr.cc` homepage (no sitemap exists)
- Monitor `cleanshot.com/sitemap.xml` for new URLs
- Poll `shottr.cc/api/version.json` for release tracking
- Watch for new URLs containing "ai", "team", "enterprise" — signals they're moving upmarket

---

## Backlog (Not Prioritized)

These are features identified in the competitive analysis as "skip for now" but worth revisiting later if demand appears.

| Feature | Notes |
|---------|-------|
| Screen recording | Different product category entirely |
| Scrolling capture | Complex, diminishing returns for students |
| Cloud upload/sharing | Infrastructure cost, not core value prop |
| Background/backdrop tool | Gradient backgrounds for social media posts |
| Color picker | Tab-while-zoomed to sample colors — design tool feature |
| Desktop icon hiding | Toggle desktop icons off for clean captures |
| S3/cloud storage integration | Enterprise feature, not student-focused |

---

## Priority Order

If you're asking "what do I do tomorrow morning," here's the sequence:

```
1.  Icons (App + Menu Bar)          ← Unblocks visual identity
2.  Apple Developer account         ← Unblocks signing
3.  Code signing + notarization     ← Unblocks distribution
4.  Landing page (caloura.app)     ← Unblocks downloads + Sparkle
5.  Sparkle EdDSA key               ← Unblocks auto-updates
6.  DMG packaging                   ← First distributable build
7.  Test coverage (Phase 8A/8B)     ← Confidence for future changes
8.  Raycast extension               ← First viral distribution channel
9.  Homebrew cask                   ← Second distribution channel
10. GitHub Actions CI               ← Automated quality gate
11. .edu pricing flow               ← Biggest competitive moat
```
