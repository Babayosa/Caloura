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

### Release preflight must exercise the real packaging path
- **Rule**: A release-readiness script must run the full archive/export/sign/notarize flow by default. Guard-only metadata checks are useful, but they are not sufficient for a release decision.
- **Context**: Local validations can all pass while the real release still fails on export, signing identity drift, missing notarization credentials, or packaging-only warnings.
- **Example**: `scripts/release_ready.sh` now defaults to the full `scripts/release.sh` path, with `--guard-only` as an explicit escape hatch for local guard runs.

### XCTest lifecycle overrides should stay nonisolated
- **Rule**: Keep `XCTestCase` lifecycle overrides nonisolated and isolate only the work inside them.
- **Context**: Annotating `setUp` / `tearDown` overrides with `@MainActor` triggers Swift 6 override-isolation warnings even when the tested objects are main-actor bound.
- **Example**: `CalouraUITests`, `ScreenCaptureManagerTests`, and `LicenseManagerSignedBackendTests` now use nonisolated lifecycle overrides plus `MainActor.assumeIsolated` for the specific setup state they need.

### Return actor-isolated test state instead of mutating `self` inside actor closures
- **Rule**: When using `MainActor.assumeIsolated` in test setup, return the prepared values and assign them afterward.
- **Context**: Capturing and mutating test-case properties inside the actor closure can trigger “sending self risks causing data races” warnings in Xcode test builds.
- **Example**: `CalouraUITests.setUpWithError()` now returns `(XCUIApplication, XCUIElement)` from the actor closure and assigns both properties after the closure exits.

### Type-ID-guarded CF bridges do not need `unsafeBitCast`
- **Rule**: After validating a CoreFoundation type with its runtime type ID, prefer a normal forced cast over `unsafeBitCast`.
- **Context**: The runtime type check already establishes the expected CF type, so `unsafeBitCast` adds no value and increases the apparent crash surface in audits.
- **Example**: `AXElementHandle`, `AXValueHandle`, and `SecRequirementHandle` now use `as!` after `CFGetTypeID(...)` guards instead of `unsafeBitCast(...)`.

## Capture / Scroll

### Manual scroll capture should accept one final settled frame on Finish
- **Rule**: When the user finishes a manual scroll capture, run one last settle-and-accept pass before finalizing.
- **Context**: Manual finish can race the final viewport change; ending immediately after the finish signal can drop the user’s last settled scroll position and create flaky or truncated output.
- **Example**: `ScrollCaptureEngine.runManualCapture(...)` now performs a final manual settle when `Finish` is requested and appends that frame if it produces meaningful new content.

## Capture / UX

### Area capture feedback must not wait on frozen screenshots
- **Rule**: Present the selection overlay and crosshair immediately when area capture starts, then backfill frozen screen imagery asynchronously.
- **Context**: If overlay presentation is blocked on a freeze snapshot, the app appears unresponsive and users miss the mode change cue even when capture actually started.
- **Example**: `CapturePipeline.captureArea()` now creates the overlays through `AreaCaptureSessionCoordinator` before `freezeScreenshots()` completes, and updates the overlay backgrounds later.

### Frozen selection backgrounds should exclude Caloura explicitly
- **Rule**: When building a frozen background for capture selection, use a display-scoped `SCContentFilter` that excludes the current app instead of taking a plain display screenshot.
- **Context**: Once the overlay is visible, generic fullscreen screenshots can echo Caloura or degrade into wallpaper-only artifacts depending on window level and display topology.
- **Example**: `ScreenCaptureManager.captureFrozenDisplaySnapshot(screen:)` now resolves the `SCDisplay` plus Caloura's `SCRunningApplication`, excludes the app, and captures with `SCScreenshotManager.captureImage(contentFilter:configuration:)`.

### Selection overlays should avoid screen-saver window semantics
- **Rule**: Use non-activating panels at overlay-window level for routine capture selection overlays; do not use `.screenSaver` unless you explicitly want system takeover behavior.
- **Context**: `.screenSaver` can cause open app windows to disappear beneath the selection surface, especially in multi-display capture flows.
- **Example**: `CaptureOverlayWindow` and `ScreenSelectionOverlayWindow` now stay as `.nonactivatingPanel` instances but use `CGWindowLevelForKey(.overlayWindow)` instead of `.screenSaver`.

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

## Onboarding / Distribution

### [Graduated] Direct-download macOS apps should ship in a Finder-style DMG
- **Rule**: For manual website downloads, distribute a signed/notarized DMG that contains the app plus an `/Applications` shortcut, and reserve ZIP artifacts for updater channels like Sparkle.
- **Context**: Launching a freshly unzipped app from Downloads leaves install path and translocation state unstable, which turns first-run onboarding and TCC repair into guesswork.
- **Example**: Caloura now publishes a branded DMG for manual installs, keeps ZIP output for Sparkle, and blocks onboarding on moving the app into `/Applications` first.

### [Graduated] Passive Screen Recording grant is not the same as a working capture copy
- **Rule**: Treat `CGPreflightScreenCaptureAccess()` as a coarse grant check only; do not mark Screen Recording as working until the current installed app copy succeeds at real ScreenCaptureKit validation, and do not bounce back to denial purely because CG stays false after a recent explicit grant attempt.
- **Context**: TCC can report a grant for a stale or moved app record even when the active app bundle still cannot capture, especially after duplicate copies or path changes. On macOS 26, the opposite failure also appears in practice: same-process CG can stay stale after the user enables Screen Recording, while a live SCK validation path is the only trustworthy way to decide whether to proceed, keep waiting, or relaunch once.
- **Example**: `PermissionCoordinator` now distinguishes passive denial from post-Settings validation, keeps onboarding in the waiting flow while SCK retries run, trusts a successful live validation for the rest of the current launch, and performs one automatic relaunch only after the explicit post-Settings grace window expires.

### [Graduated] Passive fingerprint mismatch should not trigger onboarding repair by itself
- **Rule**: A stored identity mismatch is advisory only. Do not show stale-copy repair UI until the current app copy fails a real capture validation and a single silent repair retry.
- **Context**: Development machines routinely accumulate `/Applications`, Downloads, DerivedData, archive, and export copies. Treating that mismatch as a passive startup failure produces false negatives even when the installed app can capture correctly.
- **Example**: Caloura now keeps passive status at `grantedNeedsValidation`, primes SCK silently on the first-capture screen, and only emits `.staleRecord` after live validation plus replayd repair both fail.

### Permission-repaired UI must only follow a working validation
- **Rule**: Do not transition onboarding to its repaired/completed state on `grantedNeedsValidation`. Reserve completion for `.working`.
- **Context**: Same-copy stale CoreGraphics state can keep Screen Recording in a validation-needed state even after the app has enough evidence to avoid a hard denial. Showing “Permission repaired” too early makes the next failed capture look like a contradiction instead of an unfinished validation path.
- **Example**: `OnboardingView.handlePermissionStatus(...)` now keeps completed users in the repair/validation step while status is `grantedNeedsValidation`, and `AppDelegate.onboardingState(...)` maps only `.working` to `.completed`.

### [Graduated] DMG install windows need dedicated neutral artwork
- **Rule**: Use a purpose-built neutral background asset for the drag-to-Applications DMG window instead of repurposing product icons or in-app branding art.
- **Context**: DMG install surfaces are Finder UI, not in-app onboarding. Reusing product artwork there reads as improvised and undermines the install presentation.
- **Example**: `scripts/release.sh` now requires `scripts/assets/dmg-neutral-background.png` and fails fast if the neutral DMG background asset is missing.

## Persistence / Data Integrity

### Async history saves need monotonic revisions
- **Rule**: When main-actor state snapshots are persisted via background tasks, tag each snapshot with a monotonic revision and drop stale revisions on the writer side.
- **Context**: Actor serialization alone does not prevent older snapshots from arriving after newer ones if they are enqueued from separate tasks.
- **Example**: `AppState.saveHistoryNow()` now increments `historyRevision`, and `HistoryPersistenceWorker` skips any revision older than the latest one already requested.

### Smart filenames still need uniqueness at write time
- **Rule**: Human-friendly or AI-generated filenames must be uniqued at save time, even if the base filename generation logic is deterministic.
- **Context**: Reusing the same smart title for multiple captures will otherwise overwrite earlier artifacts despite having “better” names.
- **Example**: `FileOrganizer.save(...)` now resolves `release-notes.png`, `release-notes-2.png`, and so on before writing the file to disk.
