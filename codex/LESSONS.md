# Lessons Learned — Caloura

Historical lessons recorded before this file existed still live in `tasks/lessons.md`.

## Architecture / DI

### Singleton debt usually sits at call-site edges, not inside already-injectable services
- **Rule**: When auditing global state, check whether the service itself already has an injected initializer before planning a rewrite. If it does, remove `.shared` lookups from callers first.
- **Context**: `PermissionCoordinator`, `ScreenCaptureManager`, `CapturePipeline`, and `ScreenshotArtifactCoordinator` already have meaningful constructor seams. The remaining architectural debt is mostly UI and controller code bypassing those seams with direct `.shared` access.
- **Example**: `AppCommandController` and `QuickAccessOverlay` still call `CapturePipeline.shared` directly even though `CapturePipeline` already has a large testing initializer that can support injected command handling.

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

### Xcode app builds can surface sendability errors that SwiftPM misses
- **Rule**: After `swift build` passes, still run an Xcode build path when a target uses cached Cocoa framework objects in static storage.
- **Context**: SwiftPM accepted `EmbeddingEngine`'s cached `NLEmbedding` statics, but the Xcode app-scheme build rejected them as concurrency-unsafe because `NLEmbedding` is not `Sendable`.
- **Example**: Task 12's targeted `xcodebuild test` exposed `EmbeddingEngine.swift` as a strict-concurrency blocker even though the new coverage tests and `swift build` were green.

### Tighten hard lint thresholds only after auditing current hard-fail candidates
- **Rule**: Before lowering a SwiftLint error threshold, identify the existing code that would newly cross the hard-fail line and fix or rule it out first.
- **Context**: Task 13 lowered `line_length.error` from 300 to 200. The repo only had one source line above 200, so the safe change was to rewrite that call site instead of discovering the breakage through a failed validation loop.
- **Example**: `CapturePerformanceRecorder.swift` now builds its summary log through a prebuilt string, which kept both `swiftlint` and the Swift 6 builds green after the stricter cap was enabled.

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

### [Graduated] DMG install windows need dedicated neutral artwork
- **Rule**: Use a purpose-built neutral background asset for the drag-to-Applications DMG window instead of repurposing product icons or in-app branding art.
- **Context**: DMG install surfaces are Finder UI, not in-app onboarding. Reusing product artwork there reads as improvised and undermines the install presentation.
- **Example**: `scripts/release.sh` now requires `scripts/assets/dmg-neutral-background.png` and fails fast if the neutral DMG background asset is missing.

### Window picker activation should happen in one layer only
- **Rule**: The window-capture entry path should activate the app exactly once, inside the picker coordinator that owns presentation timing.
- **Context**: Duplicating `NSApplication.shared.activate(...)` in both the pipeline entrypoint and the coordinator adds avoidable AppKit churn and muddies window-picker performance metrics on the hot path.
- **Example**: `CapturePipeline.captureWindow()` no longer activates the app directly; `WindowCaptureSessionCoordinator.pick()` owns activation and records the `app_activated` event.

## Persistence / Data Integrity

### Async history saves need monotonic revisions
- **Rule**: When main-actor state snapshots are persisted via background tasks, tag each snapshot with a monotonic revision and drop stale revisions on the writer side.
- **Context**: Actor serialization alone does not prevent older snapshots from arriving after newer ones if they are enqueued from separate tasks.
- **Example**: `AppState.saveHistoryNow()` now increments `historyRevision`, and `HistoryPersistenceWorker` skips any revision older than the latest one already requested.

### Smart filenames still need uniqueness at write time
- **Rule**: Human-friendly or AI-generated filenames must be uniqued at save time, even if the base filename generation logic is deterministic.
- **Context**: Reusing the same smart title for multiple captures will otherwise overwrite earlier artifacts despite having “better” names.
- **Example**: `FileOrganizer.save(...)` now resolves `release-notes.png`, `release-notes-2.png`, and so on before writing the file to disk.

## Performance / Memory

### Full-canvas image assembly should not clone the final buffer
- **Rule**: When building a large RGBA canvas for export, transfer ownership of the finished pixel buffer directly to Core Graphics instead of copying it into a second `Data` object.
- **Context**: Scroll-capture stitching already holds the full output in memory. Re-wrapping that canvas through `Data(pixels)` doubles peak resident memory right at the largest allocation point.
- **Example**: `ScrollCaptureHelpers.makeImage(...)` now uses `Data(bytesNoCopy:deallocator:)` so a 20,000 px stitched capture does not incur a second full-height canvas copy.

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
