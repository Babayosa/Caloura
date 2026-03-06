# Lessons Learned — Caloura

Historical lessons recorded before this file existed still live in `tasks/lessons.md`.

## Security / Licensing

### Licensed state must come from a verifiable artifact
- **Rule**: Treat local activation booleans as migration input only. Current licensed state must be derived from a valid encrypted entitlement with bounded refresh and expiry timestamps.
- **Context**: `UserDefaults` booleans are trivial to tamper with and survive offline. The app needs a trustable local source of truth even before a dedicated entitlement backend is wired.
- **Example**: `AppSettings.isLicenseActivated` is now derived from `currentLicenseEntitlement?.isCurrentlyValid(...)` instead of acting as the authoritative flag.

## Security / Testing

### Keychain-backed crypto needs a deterministic test seam
- **Rule**: When moving runtime secrets from files into Keychain, keep a DEBUG-only override for tests that need deterministic storage and cleanup.
- **Context**: Swift package tests and isolated test runs cannot rely on shared Keychain state without becoming flaky or order-dependent.
- **Example**: `HistoryCrypto` now stores its root key in Keychain by default, but package tests can switch to a temp-directory override with `setSecurityDirectoryForTesting(...)`.

## Third-Party Libraries

### Sparkle update cycles must distinguish no-update from failure
- **Rule**: Model Sparkle's update result as explicit state and classify callback errors instead of collapsing them into "up to date."
- **Context**: Network errors, appcast mismatches, and unsupported-system failures otherwise disappear into the same user-visible state as a clean no-update check.
- **Example**: `UpdateManager` now exposes `.upToDate` and `.failed(errorSummary:)` separately and drives both from `updater(_:didFinishUpdateCycleFor:error:)`.

## Build / Project Generation

### Regenerate the Xcode project after adding source files
- **Rule**: After adding new Swift files under `Caloura/`, run `xcodegen generate` before trusting `xcodebuild`.
- **Context**: SwiftPM target-path builds can compile new files immediately, but the checked-in Xcode project will not see them until regeneration.
- **Example**: `swift test` compiled `AppCommand.swift`, but `xcodebuild build` failed until `xcodegen generate` added the file to the app target.

## Capture / UX

### Area capture feedback must not wait on frozen screenshots
- **Rule**: Present the selection overlay and crosshair immediately when area capture starts, then backfill frozen screen imagery asynchronously.
- **Context**: If overlay presentation is blocked on a freeze snapshot, the app appears unresponsive and users miss the mode change cue even when capture actually started.
- **Example**: `CapturePipeline.captureArea()` now creates the overlays through `AreaCaptureSessionCoordinator` before `freezeScreenshots()` completes, and updates the overlay backgrounds later.

### Rect-based SCK capture should be the default for area and fullscreen
- **Rule**: Use `SCScreenshotManager.captureImage(in:)` for area/fullscreen capture and reserve `SCShareableContent` fetches for window-specific workflows.
- **Context**: Area/fullscreen capture already has a concrete display-space rect. Pulling `SCShareableContent` into that path adds unnecessary warm/cold latency and more failure surface.
- **Example**: `ScreenCaptureManager.sckCaptureArea` and `sckCaptureFullScreen` now convert to display-space rects and capture directly, while window picker prewarm remains the only shareable-content cache path.

## Capture / Scroll

### Zero-displacement must stay in bounded overlap searches
- **Rule**: When search windows are centered around an expected scroll displacement, always keep `0` in the candidate range for downward captures.
- **Context**: Near the bottom of a feed, the real displacement can collapse to zero or a very small value even when the previous step was large. Excluding `0` turns that state into a false mismatch and truncates capture early.
- **Example**: `ScrollCaptureHelpers.estimateDisplacement(...)` now keeps its positive search range anchored at `0...upperBound` instead of starting at `expectedDisplacement - delta`.

### Registration bands must shrink as overlap collapses
- **Rule**: Band-matching logic for scroll registration must reduce band height and band count when the remaining overlap gets small.
- **Context**: Fixed band windows work in the middle of a long feed but fail on the last partial frame, which is where separator lines and premature bottom detection show up.
- **Example**: `ScrollCaptureHelpers.meanBandDifference(...)` now derives `bandHeight` and `effectiveBandCount` from `usableHeight` so near-bottom frame pairs still produce a valid displacement estimate.
