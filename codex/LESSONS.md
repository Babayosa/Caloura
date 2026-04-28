# Lessons Learned — Caloura

Historical lessons recorded before this file existed still live in `tasks/lessons.md`.

## Architecture / DI

### Singleton debt usually sits at call-site edges, not inside already-injectable services
- **Rule**: When auditing global state, check whether the service itself already has an injected initializer before planning a rewrite. If it does, remove `.shared` lookups from callers first.
- **Context**: `PermissionCoordinator`, `ScreenCaptureManager`, `CapturePipeline`, and `ScreenshotArtifactCoordinator` already have meaningful constructor seams. The remaining architectural debt is mostly UI and controller code bypassing those seams with direct `.shared` access.
- **Example**: `AppCommandController` and `QuickAccessOverlay` still call `CapturePipeline.shared` directly even though `CapturePipeline` already has a large testing initializer that can support injected command handling.

### Post-capture execution should live outside the capture entry coordinator
- **Rule**: Once capture request resolution, processing, preview publication, distribution, and deferred save/enrichment all live on the same post-capture path, extract that path into its own service instead of keeping it inline in the entry coordinator.
- **Context**: `CapturePipeline` still needs to own entry points, overlay/session state, and coordinator construction. Mixing those concerns with the full post-capture flow turns one hot-path type into the regression surface for both UX timing and artifact processing.
- **Example**: Task 18 moved `performCapture(...)`, capture error messaging, preview publication, distribution, and deferred save/enrichment into `CaptureExecutionService`, leaving `CapturePipeline` focused on capture orchestration.

### Capture hot-path state should move with entry orchestration
- **Rule**: When splitting capture entry/session startup out of `CapturePipeline`, move the overlay/session references and session-identity bookkeeping into a dedicated state container instead of leaving the new service coupled to scattered pipeline properties.
- **Context**: Extracting the behavior without extracting the small mutable session state would keep stale-callback guards, delayed-task ownership, and first-interaction metrics spread across multiple extensions, which defeats most of the maintainability gain from the split.
- **Example**: Task 19 introduced `CaptureSessionState` and `CaptureEntrypointService`, so area/fullscreen/window/delayed capture entry flows share one lifecycle owner for overlays, countdown tasks, tracked session IDs, and first-mouse-down state.

## Security / Licensing

### Licensed state must come from a verifiable artifact
- **Rule**: Treat local activation booleans as migration input only. Current licensed state must be derived from a valid encrypted entitlement with bounded refresh and expiry timestamps.
- **Context**: `UserDefaults` booleans are trivial to tamper with and survive offline. The app needs a trustable local source of truth even before a dedicated entitlement backend is wired.
- **Example**: `AppSettings.isLicenseActivated` is now derived from `currentLicenseEntitlement?.isCurrentlyValid(...)` instead of acting as the authoritative flag.

### Legacy license migration must not reconstruct entitlement from mutable defaults alone
- **Rule**: Compatibility migration may import a trusted legacy artifact, but it must not mint fresh entitlement windows from `UserDefaults` flags or plaintext fallback values.
- **Context**: A mirrored `isLicenseActivated` boolean plus plaintext `licenseKey` fallback turned the migration path into a local licensing bypass instead of a one-time recovery bridge.
- **Example**: `AppSettings.migrateLegacyActivationStateIfNeeded()` currently rebuilds a 7-day entitlement from defaults-backed state; future hardening should only allow that path immediately after a successful legacy keychain migration result.

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

### Regenerate the Xcode project after deleting source files
- **Rule**: After removing Swift files that are still tracked by the Xcode project, run `xcodegen generate` before trusting `xcodebuild`.
- **Context**: SwiftPM can stop compiling a deleted file immediately, but the checked-in `.xcodeproj` can still reference it and fail the Xcode build until regeneration removes the stale entry.
- **Example**: Deleting `Caloura/Capture/CaptureWindow.swift` compiled fine under SwiftPM, but `xcodebuild test -only-testing:CalouraSystemTests` failed until `xcodegen generate` rewrote `Caloura.xcodeproj`.

### Release preflight must exercise the real packaging path
- **Rule**: A release-readiness script must run the full archive/export/sign/notarize flow by default. Guard-only metadata checks are useful, but they are not sufficient for a release decision.
- **Context**: Local validations can all pass while the real release still fails on export, signing identity drift, missing notarization credentials, or packaging-only warnings.
- **Example**: `scripts/release_ready.sh` now defaults to the full `scripts/release.sh` path, with `--guard-only` as an explicit escape hatch for local guard runs.

### Release build numbers should come from release metadata, not timestamps
- **Rule**: Release archive overrides should use deterministic release metadata for the build number so equivalent release inputs produce equivalent artifacts.
- **Context**: Timestamped build numbers make manifests, appcast validation, and post-release comparisons drift for reasons that have nothing to do with the release contents.
- **Example**: `scripts/release.sh` now derives `CURRENT_PROJECT_VERSION` from the requested semantic release version with a stable numeric mapping instead of `date +%Y%m%d%H%M%S` or a stale project build setting.

### Final Sparkle artifacts need extracted-app signature validation
- **Rule**: After stapling and rebuilding the Sparkle ZIP, extract the ZIP and run strict code-signature validation on the contained `.app`; validating only the pre-staple or pre-ZIP app can miss updater-breaking artifacts.
- **Context**: A release ZIP downloaded from the live appcast passed size/signature metadata checks but contained an app that failed `codesign --verify --deep --strict`, causing Sparkle to download the update and then fail during installation.
- **Example**: `scripts/release.sh` now verifies the stapled app and the final extracted ZIP app with `codesign --verify --deep --strict`, and the project no longer embeds a false `com.apple.security.app-sandbox = false` entitlement.

### Live appcast validation belongs in publish, not pre-release gating
- **Rule**: Keep local appcast/manifest validation in pre-release checks, but validate the live feed only after the publish step updates the site repo.
- **Context**: Pre-release gates should not depend on GitHub Pages propagation or a feed that has not been published yet; those checks belong to the publish path where the live artifact actually exists.
- **Example**: `scripts/release_ready.sh` now stops after local packaging checks, while `scripts/publish.sh` retries live `appcast.xml` validation after pushing the site repo.

### XCTest lifecycle overrides should stay nonisolated
- **Rule**: Keep `XCTestCase` lifecycle overrides nonisolated and isolate only the work inside them.
- **Context**: Annotating `setUp` / `tearDown` overrides with `@MainActor` triggers Swift 6 override-isolation warnings even when the tested objects are main-actor bound.
- **Example**: `CalouraUITests`, `ScreenCaptureManagerTests`, and `LicenseManagerSignedBackendTests` now use nonisolated lifecycle overrides plus `MainActor.assumeIsolated` for the specific setup state they need.

### Return actor-isolated test state instead of mutating `self` inside actor closures
- **Rule**: When using `MainActor.assumeIsolated` in test setup, return the prepared values and assign them afterward.
- **Context**: Capturing and mutating test-case properties inside the actor closure can trigger “sending self risks causing data races” warnings in Xcode test builds.
- **Example**: `CalouraUITests.setUpWithError()` now returns `(XCUIApplication, XCUIElement)` from the actor closure and assigns both properties after the closure exits.

### Type-ID-guarded CF bridges do not need `unsafeBitCast`
- **Rule**: After validating a CoreFoundation type with its runtime type ID, avoid `unsafeBitCast`; use the narrowest cast form that both Swift and SwiftLint accept.
- **Context**: Normal forced casts work for some CF wrappers, but Security CF aliases can make Swift reject optional casts as always succeeding while SwiftLint rejects `as!`. A type-ID guard plus `unsafeDowncast` is acceptable for that shape because the runtime type has already been proven.
- **Example**: `AXElementHandle` and `AXValueHandle` use normal casts after `CFGetTypeID(...)`; `SecRequirementHandle` uses a type-ID guard before `unsafeDowncast(...)` because `as? SecRequirement` does not compile and `as! SecRequirement` fails lint.

### Xcode app builds can surface sendability errors that SwiftPM misses
- **Rule**: After `swift build` passes, still run an Xcode build path when a target uses cached Cocoa framework objects in static storage.
- **Context**: SwiftPM accepted `EmbeddingEngine`'s cached `NLEmbedding` statics, but the Xcode app-scheme build rejected them as concurrency-unsafe because `NLEmbedding` is not `Sendable`.
- **Example**: Task 12's targeted `xcodebuild test` exposed `EmbeddingEngine.swift` as a strict-concurrency blocker even though the new coverage tests and `swift build` were green.

### Tighten hard lint thresholds only after auditing current hard-fail candidates
- **Rule**: Before lowering a SwiftLint error threshold, identify the existing code that would newly cross the hard-fail line and fix or rule it out first.
- **Context**: Task 13 lowered `line_length.error` from 300 to 200. The repo only had one source line above 200, so the safe change was to rewrite that call site instead of discovering the breakage through a failed validation loop.
- **Example**: `CapturePerformanceRecorder.swift` now builds its summary log through a prebuilt string, which kept both `swiftlint` and the Swift 6 builds green after the stricter cap was enabled.

### Coverage gates close fastest through named seams, not anonymous defaults
- **Rule**: If a release coverage gate misses a callback-heavy private path, extract named injectable seams instead of relying on anonymous default-argument closures or deeply private helpers.
- **Context**: The permission coverage gate kept missing `captureMinimalScreenshot(...)` and the default minimal-probe closures because the only live path was buried behind private callback glue and anonymous defaults that were hard to target directly in tests.
- **Example**: `ScreenCaptureManager+Permission.swift` now exposes `mainDisplayBounds`, `systemMinimalScreenshotCapture`, `defaultMinimalScreenshotProbe`, and `captureMinimalScreenshot(...)` as named static seams, and the release guard’s coverage gate now passes.

### Pending capture replay must survive only real relaunch paths
- **Rule**: Keep pending capture replay armed only when the permission flow actually requests a relaunch; clear it on silent repair, cooldown suppression, or non-relaunch alert actions.
- **Context**: Arming replay too early made the exact capture mode leak into later unrelated launches, which could auto-dispatch a stale capture long after the original permission failure was resolved or abandoned.
- **Example**: `PermissionCoordinator.handleCapturePermissionFailure()` now clears pending resume unless the alert path actually requested restart, while onboarding and auto-relaunch flows still preserve the intended mode when a real relaunch occurs.

## Capture / Scroll

### Manual scroll capture should accept one final settled frame on Finish
- **Rule**: When the user finishes a manual scroll capture, run one last settle-and-accept pass before finalizing.
- **Context**: Manual finish can race the final viewport change; ending immediately after the finish signal can drop the user’s last settled scroll position and create flaky or truncated output.
- **Example**: `ScrollCaptureEngine.runManualCapture(...)` now performs a final manual settle when `Finish` is requested and appends that frame if it produces meaningful new content.

## Capture / Error Handling

### Capture errors need separate user and log surfaces
- **Rule**: Keep technical capture failure detail in a dedicated log field, and make `errorDescription` / status messages recovery-oriented instead of dumping raw subsystem text.
- **Context**: ScreenCaptureKit and CLI failures often include implementation detail that is useful for logs but confusing or unactionable in UI surfaces like `AppState.statusMessage` and scroll progress overlays.
- **Example**: `CaptureError` now exposes `userMessage` and `logMessage`, `CapturePipeline.performCapture(...)` uses the user message for status text, and logs preserve reasons like failed SCK/CLI image production separately.

## Concurrency / Sendability

### `@unchecked Sendable` on mutable classes needs real synchronization, not just trusted call sites
- **Rule**: If a type claims `@unchecked Sendable` and still has mutable state, protect that state internally with a lock or actor even if current production callers already happen to serialize access.
- **Context**: Protocol requirements and future call sites outlive today’s usage assumptions. Relying on “the actor currently calls this serially” is weaker than making the type itself safe.
- **Example**: `DefaultScrollDriver` now locks `hasStartedScroll` because `ScrollDriving` is `Sendable`; actor-serialized scroll capture calls alone were not enough to justify the unchecked conformance.

### Queue-backed global helpers must be reentrant-safe
- **Rule**: If a serial-queue helper can be called both inside and outside the owning queue, guard it with queue-specific re-entry detection instead of blindly calling `dispatch_sync`.
- **Context**: Moving unsafe globals behind a serial queue fixes races, but nested helper access from within that queue can crash the process with a libdispatch self-deadlock trap.
- **Example**: `HistoryCrypto` now uses `keyQueueSync(...)` with a `DispatchSpecificKey` so `getOrCreateKey()` can call override helpers while already executing on `keyQueue` without triggering the SwiftPM `signal code 5` crash.

### One-shot stream startup has to be ordered with cancellation
- **Rule**: For a one-shot `SCStream` capture, store the stream and invoke `startCapture` under the same synchronization boundary that cancellation uses, or a timeout can still start a live stream after the operation is already finished.
- **Context**: A continuation-only timeout is not enough if cancellation can win between “continuation stored” and “stream started,” because the underlying stream may still come alive and burn resources after the caller already failed.
- **Example**: `OneShotFrozenDisplayStreamCapture.startStream()` now tears down pre-start cancellations before launch, registers the stream, and calls `startCapture` before releasing its lock so timeout/cancel cannot sneak in a live stream afterward.

## Access Control

### Tightening properties on multi-file types needs same-file mutation seams
- **Rule**: When a type is split across extension files, convert writable stored properties to `private(set)` only after adding same-file helper methods that own the mutations.
- **Context**: `private(set)` narrows the setter to the declaration file, so extension-based feature files stop compiling if they still assign the property directly.
- **Example**: `CapturePipeline` now keeps overlay/session state behind `replace...` and `clear...` helpers in `CapturePipeline.swift`, which lets entry-point and scroll-capture extensions update state without leaving the properties writable module-wide.

## Capture / UX

### Crosshair ownership must start before overlays become key
- **Rule**: Begin the shared crosshair session before ordering capture overlays front, and make only the overlay under the mouse key during presentation.
- **Context**: If AppKit gets to front or key an overlay before Caloura owns the crosshair, the system arrow can render for a frame. Making every overlay key also causes extra cursor recalculation churn on multi-display entry.
- **Example**: `AreaCaptureSessionCoordinator.present()` and `FullscreenCaptureSessionCoordinator.present()` now call `beginCrosshairSession()` before invoking the overlay presenter, while `CaptureOverlayWindow.showOnAllScreens()` and `ScreenSelectionOverlayWindow.showOnAllScreens()` front the mouse-screen panel first and keep the rest non-key.

### `.set()` is not strong enough for first-frame overlay cursor recovery
- **Rule**: In Caloura's capture overlay path, do not rely on `NSCursor.set()` to reclaim the crosshair. Reassert with balanced pop/push ownership and one coalesced next-turn re-prime instead.
- **Context**: The timer-based watchdog could be removed, but live AppKit still recomputed cursor state after the overlay became key and reclaimed the arrow on the first visible frame when reassertion only called `.set()`.
- **Example**: `CaptureCursorController` now keeps a single push/pop session, reinstalls the crosshair with pop/push, and schedules one bounded deferred re-prime plus `didBecomeActive` re-prime coverage while capture is active.

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

### Selection cursor updates should not depend on key-window state
- **Rule**: Area-selection cursor tracking should stay active even if AppKit has not yet made the nonactivating overlay key, and overlay presentation should explicitly set the crosshair during view/window priming.
- **Context**: Nonactivating panels can briefly miss key-window cursor-update delivery, which makes the selection overlay visible while the cursor remains an arrow until another event re-primes it.
- **Example**: `RegionSelectionView` now uses an `.activeAlways` cursor-update tracking area, and overlay/window reuse paths call `handleCursorUpdate()` before scheduling deferred re-prime.

### Cursor re-prime scheduling must not debounce mouse movement
- **Rule**: Capture cursor re-prime should keep the first pending action instead of canceling and rescheduling it on every mouse/cursor event.
- **Context**: A debounce can starve the only strong pop/push crosshair reassertion while the user keeps moving the mouse into the area overlay, leaving AppKit's arrow cursor visible throughout selection mode.
- **Example**: `CaptureCursorController.scheduleReprime()` now returns when a re-prime is already pending, allowing the pending action to run and reclaim crosshair ownership.

### Mouse movement must synchronously own the capture cursor
- **Rule**: During capture selection, mouse-entered and mouse-moved handling must synchronously reinstall the crosshair with balanced push/pop ownership; delayed re-prime alone is not sufficient.
- **Context**: AppKit can recompute cursor state during active mouse movement and briefly restore the arrow between delayed re-primes. Calling only `NSCursor.set()` or scheduling a later repair leaves visible flicker.
- **Example**: `RegionSelectionView.mouseMoved` now calls `handleCursorUpdate()`, and `CaptureCursorController.handleCursorUpdate()` uses the same push-before-pop reinstall path as deferred re-prime.

### Capture cursor lifetime should be token-owned
- **Rule**: Capture overlay coordinators should hold an explicit cursor-session token and end it after hiding/tearing down overlays; do not rely on scattered paired begin/end calls.
- **Context**: Repeated area capture reuses `NSPanel` and selection-view instances. If stale callbacks, pool teardown, or a previous coordinator can pop/reset cursor state outside the active coordinator's ownership, the next area entry can present with the arrow cursor instead of the crosshair.
- **Example**: `CaptureCursorController.startCrosshairSession()` now returns a session token, and `AreaCaptureSessionCoordinator.releaseOverlays()` orders pooled panels out before ending that token.

### Every capture overlay mode must prime the cursor synchronously
- **Rule**: Fullscreen and area overlay presentation must both force cursor-rect registration and call `handleCursorUpdate()` immediately after ordering overlays front; mouse movement cannot be the first reliable repair.
- **Context**: After switching capture modes, fullscreen selection could leave AppKit showing the arrow until movement triggered a view-level cursor event because fullscreen only scheduled a deferred re-prime.
- **Example**: `FullscreenCaptureSessionCoordinator.present()` now mirrors the area path by resetting overlay cursor rects, calling `handleCursorUpdate()`, then scheduling a deferred re-prime; `ScreenSelectionView` also synchronously reasserts on entry/move/down.

### Full-screen apps can keep reclaiming the cursor after initial capture priming
- **Rule**: Active area/fullscreen capture sessions should keep a bounded maintenance re-prime alive until the cursor-session token ends.
- **Context**: Apps in their own full-screen Spaces, especially apps with custom cursor behavior, can continue to run cursor-rect updates after Caloura's one-shot entry re-prime and restore the arrow during selection.
- **Example**: `CaptureCursorController` now schedules a 50 ms maintenance re-prime during the active crosshair session and cancels it on token end/reset, keeping push/pop ownership balanced while the selection overlay is visible.

### Capture mode must not depend on the native cursor being visible
- **Rule**: During area/fullscreen capture, hide the native cursor and render Caloura's visible crosshair inside the overlay.
- **Context**: Repeated desktop captures and full-screen apps can still show the arrow when AppKit cursor rects or the native cursor stack lag behind overlay presentation. Re-prime loops improve the race but do not remove it.
- **Example**: `CaptureCursorController` now balances `NSCursor.hide()`/`unhide()` per session, while `RegionSelectionView` and `ScreenSelectionView` draw their own crosshair at the current pointer location.

### Rendered capture cursors need an invisible native fallback
- **Rule**: Once Caloura renders its own capture crosshair, any native cursor pushed during capture must be transparent rather than another visible crosshair.
- **Context**: `NSCursor.hide()` is still AppKit-owned and can briefly lose to cursor rect recalculation. If the fallback cursor is visible, users can see both the system cursor and Caloura's rendered crosshair.
- **Example**: `SystemCaptureCrosshairDriver` now pushes/sets a 1x1 transparent cursor while the overlay draws the only visible crosshair.

### Capture hot-path guardrails should warn before they fail UI tests
- **Rule**: For AppKit-heavy capture timing, record lightweight budget violations in the performance timeline before turning them into hard test failures.
- **Context**: Full-screen Spaces and cursor rect delivery vary by app and machine. Hard timing assertions can create flaky tests, while missing instrumentation makes production regressions hard to diagnose.
- **Example**: `CapturePerformanceRecorder` now logs warning-only `capture_timeline_budget_violation` entries for overlay visibility, cursor priming, overlay teardown, and raw preview latency.

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

### Passive permission refresh must preserve an explicit repair diagnosis
- **Rule**: Once the current app identity has been explicitly diagnosed as `.needsRelaunch` or `.staleRecord`, passive refresh must preserve that diagnosis until a new permission request, denial, or working validation replaces it.
- **Context**: Reverting a proven repair state back to `.grantedNeedsValidation` recreates the exact contradictory UX this pipeline is supposed to avoid: macOS still fails live capture, but the app falls back to generic “check again” messaging.
- **Example**: `PermissionCoordinator` now stores an in-memory diagnosed failure for the active identity and reuses it inside `refreshPassiveStatus(...)` instead of collapsing immediately to the passive grant state.

### Permission-repaired UI must only follow a working validation
- **Rule**: Do not transition onboarding to its repaired/completed state on `grantedNeedsValidation`. Reserve completion for `.working`.
- **Context**: Same-copy stale CoreGraphics state can keep Screen Recording in a validation-needed state even after the app has enough evidence to avoid a hard denial. Showing “Permission repaired” too early makes the next failed capture look like a contradiction instead of an unfinished validation path.
- **Example**: `OnboardingView.handlePermissionStatus(...)` now keeps completed users in the repair/validation step while status is `grantedNeedsValidation`, and `AppDelegate.onboardingState(...)` maps only `.working` to `.completed`.

### Historical working state must not replace a fresh Screen Recording request
- **Rule**: Never let stored “last working” path or fingerprint suppress `CGRequestScreenCaptureAccess()` on its own. Only a real recent permission-request session or current-process live validation may override stale CoreGraphics denial.
- **Context**: After a TCC reset or deleted Screen Recording record, historical metadata can still match the current app copy. If that metadata bypasses denial, the app never reappears in System Settings because macOS never sees a new request.
- **Example**: `PermissionCoordinator.shouldTrustLiveValidationWithoutCoreGraphics(...)` now ignores historical path/fingerprint state, and `takePendingCaptureResumeIfFresh()` reconstructs the recent request session after the one automatic relaunch so the post-Settings recovery path still works.

### Permission status publication should own transition side effects
- **Rule**: Funnel Screen Recording status publication through shared coordinator helpers so working, denied, and explicit-failure transitions clear or preserve repair state the same way across passive refresh, live validation, settings-return checks, and capture-failure handling.
- **Context**: Once the permission flow grew multiple entry points, repeating the side effects inline made it too easy for one path to clear a diagnosis or permission-request session while another path preserved it. That kind of drift recreates contradictory permission UI even when the status enum itself is correct.
- **Example**: `PermissionCoordinator` now computes passive state with `passiveStatus(...)` and publishes outcomes through `publishStatus(...)`, `publishWorkingValidated(...)`, `publishDenied(...)`, and `publishExplicitFailure(...)` instead of reimplementing the same state mutation in each method.

### Pure permission rules should live outside the coordinator
- **Rule**: Keep Screen Recording status derivation, failure classification, and permission copy in a small pure helper type; leave the coordinator focused on orchestration, persistence, and side effects.
- **Context**: Even after centralizing publication, `PermissionCoordinator` still mixed repair orchestration with passive-status rules and UI rendering. That made the state machine harder to review and forced most rule changes through full coordinator tests instead of direct coverage.
- **Example**: `PermissionStatusCore` now owns passive status resolution, `.needsRelaunch` vs `.staleRecord` classification, `PermissionUIModel` rendering, and non-blocking messages, while `PermissionCoordinator` only builds context and applies side effects.

### [Graduated] DMG install windows need dedicated neutral artwork
- **Rule**: Use a purpose-built neutral background asset for the drag-to-Applications DMG window instead of repurposing product icons or in-app branding art.
- **Context**: DMG install surfaces are Finder UI, not in-app onboarding. Reusing product artwork there reads as improvised and undermines the install presentation.
- **Example**: `scripts/release.sh` now requires `scripts/assets/dmg-neutral-background.png` and fails fast if the neutral DMG background asset is missing.

### Public download QA should preserve quarantine by default
- **Rule**: Public-download validation should keep quarantine intact unless the operator explicitly opts into stripping it for a local-only install.
- **Context**: Gatekeeper behavior is part of the packaged-app contract. Removing quarantine implicitly makes a successful launch tell you less about the real download path.
- **Example**: `scripts/public_download_qa.sh` now keeps quarantine by default and only removes it when `STRIP_QUARANTINE=1` is set.

### Public download QA must verify a fresh app launch
- **Rule**: Release QA for a downloaded app must fail if it only observes an already-running process; kill or reject pre-existing app instances before launch and assert that a fresh process stays alive afterward.
- **Context**: A simple `pgrep` check can falsely pass when a developer copy of the app was already running before QA started, which makes the launch validation meaningless for production downloads.
- **Example**: `scripts/public_download_qa.sh` now stops any existing `Caloura` process before `open -a`, captures the newly launched PIDs, and fails if no fresh app process remains running.

### DMG QA cleanup must detach by the physical mount path
- **Rule**: Before cleaning a public-download QA mount directory, detach the DMG by both the requested mountpoint and its physical `pwd -P` path.
- **Context**: macOS can report `/private/var/...` in `mount` even when the script requested `/var/...`; checking only the requested path missed a live read-only DMG mount and cleanup attempted to remove mounted files.
- **Example**: `scripts/public_download_qa.sh` now resolves the physical mount path in `detach_dmg_if_needed()` before any install-phase mount directory cleanup.

### AppTranslocation must not replace a matching installed copy
- **Rule**: If a release app is running from `/private/var/.../AppTranslocation/...` and the same version/build already exists in `/Applications`, relaunch the stable installed copy after clearing quarantine instead of copying from the translocated path.
- **Context**: A quarantined installed app can launch through Gatekeeper's randomized AppTranslocation mount. Treating that path as "not installed" makes the in-app move flow try to replace `/Applications/Caloura.app` from a synthetic read-only source; however, a newer manual DMG must still be allowed to replace an older installed app.
- **Example**: `AppMover` now compares source and installed bundle version/build before choosing relaunch vs replacement; `public_download_qa.sh` fails if the launched executable path is still under AppTranslocation.

### Public download QA should poll AppTranslocation convergence
- **Rule**: When validating a quarantined installed launch, allow a short bounded poll for Caloura to self-relaunch from AppTranslocation into `/Applications` before failing.
- **Context**: Gatekeeper can start the first process from a translocated path even after the app-side fix is present; the correctness property is that the app clears quarantine and converges to `/Applications`, not that the first PID is already stable.
- **Example**: `public_download_qa.sh` now polls process executable paths for up to 60 seconds until every `Caloura` PID is `/Applications/Caloura.app/Contents/MacOS/Caloura`, then fails if convergence never happens.

### Publish reruns must be idempotent after site push
- **Rule**: Publishing should continue to live validation and public-download QA when release files are already committed to the site repo.
- **Context**: A publish can push appcast/artifact changes and then fail in post-publish QA. The next run must validate and finish the same release instead of failing on an already-published build number or empty site commit.
- **Example**: `scripts/publish.sh` now treats an equal build number as an idempotent rerun only when the local appcast already matches the manifest, then skips no-op site commits and continues with live appcast plus public-download QA.

### Permission diagnostics should separate installed-app logs from XCTest hosts
- **Rule**: Operational Screen Recording diagnostics must report installed-app logs separately from `xctest` logs so failure-path tests do not look like live permission regressions.
- **Context**: `scripts/permission_diagnose.sh` originally tailed all matching subsystem logs together, which made a healthy installed app appear denied immediately after permission tests ran.
- **Example**: The script now prints separate installed-app and test-host sections, and its actionable steps only refer to the installed-app logs.

### Window picker activation should happen in one layer only
- **Rule**: The window-capture entry path should activate the app exactly once, inside the picker coordinator that owns presentation timing.
- **Context**: Duplicating `NSApplication.shared.activate(...)` in both the pipeline entrypoint and the coordinator adds avoidable AppKit churn and muddies window-picker performance metrics on the hot path.
- **Example**: `CapturePipeline.captureWindow()` no longer activates the app directly; `WindowCaptureSessionCoordinator.pick()` owns activation and records the `app_activated` event.

### Window picker presentation should cross one main-actor turn and reject stale sessions
- **Rule**: Present the system window picker only after yielding one main-actor turn, and generation-guard the scheduled presentation so a cancelled pick session cannot still surface stale UI.
- **Context**: Immediate same-turn presentation left a small race where back-to-back `pickWindow()` requests could cancel the older session but still allow its picker presentation to reach AppKit, which is exactly the kind of edge case that shows up as transaction noise under severe audit conditions.
- **Example**: `WindowPickerManager` now schedules presentation through an injected `schedulePresentation` closure, cancels any pending presentation task in `resumeAndClear(...)`, and ignores scheduled presents whose `pickSessionID` is no longer current.

### Window picker selections should stay inside one main-actor owner
- **Rule**: Do not pass `SCContentFilter` back out through picker results. Keep the selected filter inside the main-actor picker owner and generation-guard every observer callback before resuming.
- **Context**: Guarding presentation alone is not enough. A stale observer can still deliver an old selected window into a newer request if selection, cancel, and failure callbacks are not all session-checked at the same ownership boundary.
- **Example**: `WindowPickerManager` now resumes `pickWindow()` with `.selected` only, stores the filter in `pendingFilter`, and ignores late `didUpdateWith`, cancel, and failure callbacks whose `sessionID` no longer matches `pickSessionID`.

### Window capture geometry must be validated before pixel conversion
- **Rule**: Validate window `contentRect` and `pointPixelScale` for finite, positive, in-range values before any `Int(...)` conversion or `SCStreamConfiguration` build.
- **Context**: Stale ScreenCaptureKit window selections can surface zero, non-finite, or otherwise invalid geometry. Treating that as ordinary capture input turns a recoverable unavailable-window state into a crash surface.
- **Example**: `ScreenCaptureManager.makeWindowCaptureConfiguration(...)` now rejects invalid dimensions with `CaptureError.windowUnavailable(...)` and only then routes the request through `captureFilteredScreenshot(...)`.

### Deferred save failure must stop enrichment side effects
- **Rule**: Treat deferred save as a transactional gate. If persistence fails, keep the raw preview visible but do not enqueue enrichment, history sync, or other durability-side effects.
- **Context**: Running enrichment after a failed save makes the UI behave as if the capture was durable even though the artifact never reached disk, which creates inconsistent post-capture state across modes.
- **Example**: `CaptureExecutionService.scheduleDeferredSaveAndEnrichment(...)` now only starts enrichment on `.saved` and restores the preview phase to `.rawPreviewReady` on `.failed`.

### Missing entitlements are configuration failures, not permission denials
- **Rule**: Surface ScreenCaptureKit missing-entitlement failures as configuration/build errors and keep them out of TCC repair and Settings guidance.
- **Context**: A binary without the right entitlement cannot be fixed by the user in System Settings. Misclassifying that state as permission denial sends the app into a fake repair loop and hides the real release/build defect.
- **Example**: `ScreenCaptureManager.captureErrorForSCKFailure(...)` now maps `.missingEntitlements` to `CaptureError.configurationFailed(...)`, while only actual denial cases flow into permission-repair handling.

## Persistence / Data Integrity

### Async history saves need monotonic revisions
- **Rule**: When main-actor state snapshots are persisted via background tasks, tag each snapshot with a monotonic revision and drop stale revisions on the writer side.
- **Context**: Actor serialization alone does not prevent older snapshots from arriving after newer ones if they are enqueued from separate tasks.
- **Example**: `AppState.saveHistoryNow()` now increments `historyRevision`, and `HistoryPersistenceWorker` skips any revision older than the latest one already requested.

### Smart filenames still need uniqueness at write time
- **Rule**: Human-friendly or AI-generated filenames must be uniqued at save time, even if the base filename generation logic is deterministic.
- **Context**: Reusing the same smart title for multiple captures will otherwise overwrite earlier artifacts despite having “better” names.
- **Example**: `FileOrganizer.save(...)` now resolves `release-notes.png`, `release-notes-2.png`, and so on before writing the file to disk.

### Disposable encrypted caches should self-heal on unreadable payloads
- **Rule**: If an encrypted store is a rebuildable cache rather than authoritative data, clear unreadable payloads on load failure instead of logging a persistent startup error and leaving the corrupt file in place.
- **Context**: `EmbeddingStore` backs semantic-search acceleration, not user-authored source of truth. Treating unreadable bytes as a fatal startup error just created repeating log noise and prevented automatic recovery.
- **Example**: `EmbeddingStore.load()` now logs unreadable cache payloads at debug and calls `clear()`, which removes the corrupt `embeddings.enc` file and resets in-memory state.

## Performance / Memory

### Full-canvas image assembly should not clone the final buffer
- **Rule**: When building a large RGBA canvas for export, transfer ownership of the finished pixel buffer directly to Core Graphics instead of copying it into a second `Data` object.
- **Context**: Scroll-capture stitching already holds the full output in memory. Re-wrapping that canvas through `Data(pixels)` doubles peak resident memory right at the largest allocation point.
- **Example**: `ScrollCaptureHelpers.makeImage(...)` now uses `Data(bytesNoCopy:deallocator:)` so a 20,000 px stitched capture does not incur a second full-height canvas copy.

### Unified-log perf gates need the capture run to finish before auditing
- **Rule**: When a perf gate reads unified logs, run it only after the capture workload exits and the expected events are visible in `log show`.
- **Context**: A strict perf audit can transiently report missing samples if it races the logger and runs before the latest Xcode-host capture metrics have landed in the unified log store.
- **Example**: Task 20's first strict perf pass reported missing window-picker data, but rerunning after the `CaptureSystemTests` slice finished and the `picker_visible_*` events appeared in `log show` produced a clean pass.

### Strict perf audits need samples from the real app process
- **Rule**: If release perf gates read unified logs, seed the required samples from the actual app or UI-test host process, not only from in-memory test recorders.
- **Context**: The strict audit only sees what the unified logging subsystem received from the launched app. Synthetic recorder state inside a test harness can look correct locally while still leaving the release perf gate with missing data.
- **Example**: `UITestHostWindowController.seedPerformanceAudit()` now emits the required preview and picker samples through the real app process, and `CalouraUITests.testPerformanceSeedButtonGeneratesStrictAuditSamples()` drives that path before the strict audit runs.

### Debounced UI search still blocks if the actual work never leaves the main actor
- **Rule**: If a UI path uses a debounce task, move the expensive search or scoring work onto a utility task instead of assuming the delay alone protects responsiveness.
- **Context**: The history view already waited 300 ms before semantic search, but `EmbeddingEngine.search(...)` still executed from the UI task context, so large embedding scans could still land on the main actor.
- **Example**: `HistoryView` now sleeps in its UI task, runs semantic search in `Task.detached(priority: .utility)`, and only publishes the final UUID set back on the main actor.

## AppKit / Testing

### AppKit activation paths should not rely on `NSApp` existing in SwiftPM tests
- **Rule**: When production code may run under SwiftPM tests before an app singleton is bootstrapped, call `NSApplication.shared.activate(...)` instead of force-unwrapping `NSApp`.
- **Context**: The window-capture entry path passed locally in app runs but trapped in package tests because `NSApp` was nil in those worker processes.
- **Example**: `CapturePipeline.captureWindow()` and the related window-session activation points now use `NSApplication.shared.activate(...)`, which keeps the AppKit activation behavior while avoiding nil-app test crashes.

### Full AppKit-heavy SwiftPM suites may need the one-worker runner
- **Rule**: If the default SwiftPM test driver emits runner-level signal errors around otherwise-passing AppKit tests, validate the full suite with `swift test --parallel --num-workers 1` and record that choice explicitly.
- **Context**: Caloura’s package suite completed all 466 tests cleanly under the one-worker driver, while the default driver still reported stray signal-5/11 failures around the same passing window-capture cases.
- **Example**: Task 10 used `swift test --parallel --num-workers 1` for final full-suite verification after the `NSApp` crash was fixed, because plain `swift test` still produced harness-level signal noise.

### UI-test host code should be compile-gated out of production builds
- **Rule**: If a UI-test-only controller is enabled solely by an environment flag, still wrap the code and its app-entry references in `#if DEBUG` so release builds do not compile test-host surfaces.
- **Context**: `UITestHostWindowController` was runtime-gated by `CALOURA_UI_TEST_HOST`, but the file still compiled into production and `CalouraApp` referenced it unconditionally.
- **Example**: Task 11 wrapped `UITestHostWindowController.swift` in `#if DEBUG` and moved `CalouraApp` to a DEBUG-only `isUITestHostEnabled` path.

### “Migration-only” comments must match live dependencies
- **Rule**: When auditing cleanup candidates, verify that lifecycle comments still match call sites before trusting them as removal evidence.
- **Context**: `KeychainHelper.swift` claimed to exist only for legacy migration, but `HistoryCrypto` still used it for the active history root key path.
- **Example**: Task 11 kept `KeychainHelper.swift`, documented the live `HistoryCrypto` and `AppSettings` dependencies, and updated the comment instead of deleting the file.

## Testing / Refactors

### Protocol signature changes need conformance sweeps, not just call-site sweeps
- **Rule**: When changing a protocol method signature, grep for all conformers and test doubles in addition to the production call sites before validation.
- **Context**: Updating `ScrollSettling.settle(...)` to use `ScrollSettleRequest` compiled the app target, but `swift test` still failed because `ImmediateSettler` in `ScrollCaptureEngineTests` retained the old signature.
- **Example**: After refactoring `ScrollSettling`, grep both `: ScrollSettling` and `settle(` so production implementations and synthetic test seams stay aligned.

### Async test ordering should use explicit gates, not scheduler sleeps
- **Rule**: For timing-sensitive async tests, coordinate progress with expectations, polling, or lightweight async gates instead of relying on short `Task.sleep` delays.
- **Context**: Sub-200ms sleeps were letting capture, OCR, and picker tests race the scheduler, which made failures depend on machine load instead of state transitions.
- **Example**: `CapturePipelineTests` and `ScrollCaptureEngineTests` now hold work at known points with `AsyncGate`, while deferred-history and picker tests wait through `pollUntil(...)` instead of fixed sleeps.

### Multi-slot async tests must assert causality, not start order
- **Rule**: When multiple workers are allowed to start immediately, assert the before/after relationship that matters instead of a total order between concurrently valid starts.
- **Context**: `CaptureEnrichmentCoordinator` can start two jobs in parallel. The full suite flaked because `testFinish_startsNextPendingOperationWhenASlotOpens` assumed the first enqueued job would always log before the second, even though both were allowed to run.
- **Example**: The enrichment coordinator test now checks that both initial jobs started before `start:third`, that `finish:first` opened the slot, and that `finish:third` followed `start:third`, without caring which of the first two workers logged first.

### Shared singleton state in tests must be restored at the fixture boundary
- **Rule**: If a test touches process-global state, snapshot it in `setUp()` and restore it in `tearDown()` for the whole fixture.
- **Context**: Per-test cleanup blocks were easy to miss, and leaked `activePreset`, `statusMessage`, and URL throttle state into unrelated tests.
- **Example**: `URLSchemeHandlerTests` and `ScreenCaptureManagerPermissionTests` now restore shared state from fixture-level setup/teardown instead of ad hoc teardown closures.

### Async exact-once assertions are safer as counters than over-fulfill expectations
- **Rule**: When async work can complete on background tasks after the test body has moved on, count invocations in a locked helper and assert the final total instead of relying on `assertForOverFulfill`.
- **Context**: `CapturePipelineTests` was aborting the plain SwiftPM runner because a background OCR callback could trip the over-fulfill path mid-suite, which crashed the process instead of producing a normal test failure.
- **Example**: `testSaveLastCapture_doesNotDoubleTriggerEnrichmentWhilePending` now uses `LockedCounter` plus a final `XCTAssertEqual(..., 1)` after the OCR result is observed.

### Singleton-heavy controllers can often be tested with injected routing closures
- **Rule**: When a controller mostly routes commands into global services, add a narrow closure bundle for that routing surface instead of trying to mock every singleton dependency.
- **Context**: `AppCommandController` was hard to cover because capture and distribution commands called `CapturePipeline.shared` directly, while the real coverage need was simply verifying command-to-action mapping.
- **Example**: Task 12 added `AppCommandController.Routing`, letting tests verify capture/distribution dispatch and onboarding-tip ordering without driving the live pipeline.

### Large behavior files decompose best when shared contracts move together
- **Rule**: When splitting a large subsystem, move its shared model types, errors, and protocols into one declarations-only file before touching behavior extensions.
- **Context**: Keeping AX handles, protocols, and frame/viewport models in separate tiny files left `ScrollCaptureEngine.swift` looking smaller, but the subsystem contract was still fragmented across multiple entry points.
- **Example**: `ScrollCaptureTypes.swift` now owns the shared scroll-capture enums, frames, viewport types, AX wrappers, error type, and protocols, while `ScrollCaptureEngine.swift` is reduced to engine-specific orchestration.

### Audit-driven test growth still has to respect hard fixture limits
- **Rule**: When adding targeted regression coverage to an already-large XCTest fixture, split the new tests into companion fixtures before you trip the repo’s hard `type_body_length` limit.
- **Context**: The permission coverage fix was logically correct, but piling the new probe tests into `ScreenCaptureManagerPermissionTests` caused `swiftlint lint --quiet` to fail on the hard fixture-size threshold.
- **Example**: The probe-specific tests moved into `ScreenCaptureManagerPermissionProbeTests.swift`, which kept the extra coverage while restoring the lint pass.
