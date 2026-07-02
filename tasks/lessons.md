# Lessons Learned — Caloura

<!-- Organized by topic. Graduated entries have rules in CLAUDE.md; detail kept here as reference. -->
<!-- When a lesson's rule is added to CLAUDE.md, mark it [Graduated] and trim to rule-only. -->

## AppKit / Cursor

### NSCursor.hide/unhide imbalance [Graduated]
- **Rule**: Guard `NSCursor.hide()` behind `window != nil` in `viewDidMoveToWindow()`. Use a boolean flag to balance hide/unhide exactly.
- **Context**: `viewDidMoveToWindow` fires on both add (`window != nil`) and remove (`window == nil`). Unguarded hide on removal creates a permanent imbalance.

### NSCursor.set() vs push/pop [Graduated]
- **Rule**: Use `NSCursor.crosshair.push()` to enter custom cursor mode, `NSCursor.pop()` to leave. Never use `.set()` alone — it is unreliable when the app is inactive (another app may own the cursor). Use `.set()` only inside `cursorUpdate(with:)` handler where AppKit expects it.

### macOS 26 tracking area: .activeAlways not supported for .cursorUpdate
- **Rule**: NEVER combine `.cursorUpdate` with `.activeAlways` in a single `NSTrackingArea`. macOS 26 does not support this combination. Split into two tracking areas: (1) `.cursorUpdate` + `.activeInKeyWindow` for cursor updates, (2) `.mouseMoved` + `.mouseEnteredAndExited` + `.activeAlways` for mouse tracking.
- **Mistake**: Single tracking area with `[.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways]` caused `cursorUpdate(with:)` to never fire on macOS 26, so the crosshair cursor never appeared.
- **Fix**: Two separate tracking areas. `cursorUpdate` handler calls `handleCursorUpdate()` (uses `.set()`). Mouse handlers call `scheduleReprime()` (deferred pop+push cycle). Also make hovered overlay key window on `mouseEntered`/`mouseMoved` for multi-screen cursor ownership.

### NSApp.activate() cursor race [Graduated]
- **Rule**: Never use `disableCursorRects()` if you need `addCursorRect`. Use layered defense: (1) session-scoped push/pop, (2) addCursorRect in resetCursorRects, (3) cursorUpdate → .set(), (4) didBecomeActiveNotification + activeSpaceDidChangeNotification → scheduleReprime, (5) mouseMoved/mouseEntered → scheduleReprime.
- **Context**: `disableCursorRects()` kills ALL cursor rect processing. Each layer catches a different async timing edge case.

### NSApp.activate hides windows for LSUIElement apps
- **Rule**: Never use `NSApp.activate(ignoringOtherApps: true)` before showing capture overlays. Use `NSPanel` with `.nonactivatingPanel` style mask instead of `NSWindow`. The panel receives keyboard/mouse events without activating the app, so other apps' windows remain visible.
- **Mistake**: `NSApp.activate` was called before `showOnAllScreens`, causing macOS to hide all other application windows. The idle-state dimming (0.16 alpha black) previously masked this — removing dimming revealed the bare desktop wallpaper.
- **Fix**: `CaptureOverlayWindow: NSPanel` with `styleMask: .nonactivatingPanel`, `hidesOnDeactivate = false`, `canBecomeMain = false`. Remove `NSApp.activate` from area/fullscreen coordinators. Keep it only for window capture (SCK picker requires app activation).
- **Key insight**: A non-activating panel at `.screenSaver` level can become key and receive keyboard events (ESC) without the owning app being active.

### Bridge closures must survive window pool reuse
- **Rule**: When pooling/reusing `NSWindow` instances, do NOT nil bridge closures on `tearDown`/`release`. Bridge closures (selectionView → window) delegate through the window's optional callbacks, which are nil-safe. Nilling bridge closures breaks the forwarding chain on reuse.
- **Mistake**: `tearDownHandlers()` nilled both window-level callbacks AND selectionView bridge closures. On reuse, new window callbacks were set but the selectionView could no longer reach them.
- **Fix**: Only nil window-level callbacks in `tearDownHandlers()`. Bridge closures are permanent — they use `[weak self]` + optional chaining, so they no-op when window callbacks are nil.

### All capture modes must wire cursorController
- **Rule**: Every capture mode that shows overlay windows (area, fullscreen, scroll) must pass `sessionState.cursorController` and call `beginCrosshairSession()`/`endCrosshairSession()`. Don't rely on cursor rects alone.
- **Mistake**: Scroll capture called `CaptureOverlayWindow.showOnAllScreens()` without passing a `cursorController`, relying solely on cursor rects. After scroll capture failed, subsequent area captures lost their crosshair.

### 2026-04-19 — Cursor controller state must be recoverable [domain: swift]
- **Mistake**: Post-ship 2.4.0 crosshair stopped appearing entirely on a stateful basis — once broken, it stayed broken until app restart. Capture overlay still rendered, selection still worked, but the crosshair cursor was gone.
- **Root cause**: Two interlocking defects. (1) `CaptureOverlayWindowPool.release()`/`tearDown()` ordered windows out without calling `endCrosshairSession()`, leaving the shared controller's `cursorActive=true` and `pushed=true` after any bypass path (screen reconfiguration teardown inside `acquire()`, abnormal unwind). (2) `beginCrosshairSession()` had `guard !cursorActive else { return }` for double-begin idempotency, which silently trapped the controller in the leaked state forever — every subsequent capture's begin returned early, so no push, no reprime. (3) Compounding this: `AreaCaptureSessionCoordinator.present()` called `makeKeyAndOrderFront(nil)` *before* `beginCrosshairSession()`, so `becomeKey() → primeCrosshair() → scheduleReprime()` fired while `cursorActive` was false and was silently dropped — removing one defensive layer.
- **Rule**: Add an explicit `resetCursorState()` API to the cursor controller and call it on every coordinator entry (before `beginCrosshairSession`) and inside pool teardown paths as a safety net. Keep `beginCrosshairSession`'s idempotency intact — recovery is a separate, explicit operation. Log every silent no-op (`scheduleReprime`/`handleCursorUpdate` early-return) at debug level so future regressions become observable via `log stream --level=debug --predicate 'subsystem == "com.caloura.app" AND category == "Cursor"'`.
- **Confidence**: high (root cause for two prior cursor regressions — `b75a47d`, `099d206` — would have been caught earlier with this diagnostic + recovery pattern)

## State Machines / Recovery

### 2026-04-19 — Stateful flags require a recovery API + diagnostic log + defer-based clear [domain: swift]
- **Mistake**: Across five independent sites in Caloura — `CaptureCursorController.cursorActive`, `PermissionCoordinator.isShowingAlert`, `PermissionCoordinator.inFlightValidation`, `CaptureEnrichmentService` PII scan failure swallowing, `CaptureEntrypointService` empty-screens path — a stateful flag or in-flight slot could leak set-true on an abnormal control flow (cancellation, throw, screen reconfig teardown bypass, empty `screensProvider`) and silently break every subsequent operation. Symptoms surfaced post-ship: crosshair gone forever, no second permission alert ever, PII scan errors invisible, capture path appearing to "succeed" on zero displays.
- **Root cause**: Three antipatterns compounded.
  1. **Manual paired clear after the suspending await** — e.g., `isShowingAlert = true; await present(); isShowingAlert = false` — leaks on cancellation/throw because the clear is unreachable.
  2. **Idempotency guards (`guard !flag else { return }`) with no recovery escape hatch** — once leaked, every future caller returns early; the guard meant to prevent double-arm becomes a permanent trap.
  3. **Silent swallow of failure** — catching an error and returning a sentinel without (a) a discrete phase the UI can render and (b) a status message and (c) a debug log line. The user sees "nothing happened"; engineers have nothing to grep for.
- **Rule**: Three-part pattern, applied uniformly:
  1. **`defer { flag = nil/false }`** immediately after setting any in-flight slot or presentation flag, before any `await`. The cleanup runs on every exit path including cancellation. Applies to: `isShowingAlert`, `inFlightValidation`.
  2. **Explicit recovery API + diagnostic log** for every stateful guard. `resetCursorState()` for the cursor controller; an `inflight_repair` log line for the permission alert; a `PIIScanOutcome` enum (`.skipped` / `.scanned(_)` / `.failed`) instead of optional-with-silent-fallback for PII; an empty-overlays guard with status message + log + Bool return for `presentAreaCaptureCoordinator`. Recovery is a separate, explicit operation — do NOT remove idempotency from the happy path.
  3. **Discrete failure phase + status message + log** at every catch site. New `CapturePreviewPhase.piiScanFailed` is the canonical example: the UI gets a state to render, the user gets "PII scan unavailable — capture stored unscanned.", and engineers get a structured log with input dimensions and error.
- **Diagnostic floor**: every silent early-return logs at `.debug` under `subsystem == "com.caloura.app"`, with a category that names the subsystem (`Cursor`, `Permissions`, `Enrichment`, `CaptureEntry`). Future regressions become observable via `log stream --level=debug --predicate 'subsystem == "com.caloura.app"'` instead of requiring repro and bisection.
- **Confidence**: high (5 independent sites in one phase; the same pattern would have caught two prior cursor regressions and the post-ship 2.4.0 silent-PII-failure complaints)

## Permissions / macOS

### CGWindowList false positive on Sequoia [Graduated]
- **Rule**: Never use `CGWindowListCopyWindowInfo` as a permission check. `CGPreflightScreenCaptureAccess()` is only a coarse passive signal; after an explicit Screen Recording grant attempt, use live ScreenCaptureKit validation as the authority.
- **Context**: Sequoia returns window metadata (names, owners) without screen recording permission.

### CODE_SIGNING_ALLOWED=NO strips TCC [Graduated]
- **Rule**: Only use `CODE_SIGNING_ALLOWED=NO` for CI/headless builds. Manual testing requires code signing for TCC permissions.

### Permission-repaired UI must only reflect live validation
- **Rule**: Do not show the repaired/completed Screen Recording UI until the current app copy reaches `.working`; `grantedNeedsValidation` is still an in-progress repair state.
- **Context**: Passive records and same-copy history can keep Screen Recording out of hard denial while macOS still needs one successful live validation. Showing “Permission repaired” first makes the next failed capture look contradictory.
- **Example**: `OnboardingView.handlePermissionStatus(...)` now routes `grantedNeedsValidation` back to the repair/validation step for completed users, and `AppDelegate.onboardingState(...)` maps only `.working` to `.completed`.

### Historical working state must not suppress a fresh permission request
- **Rule**: Never use stored “last working” path or fingerprint by itself to bypass `CGRequestScreenCaptureAccess()`. Only an actual recent permission-request session may keep stale `CGPreflightScreenCaptureAccess()` from forcing denial.
- **Context**: After `tccutil reset` or a removed Screen Recording record, relying on historical working metadata prevents Caloura from reappearing in System Settings because the app never re-requests permission.
- **Example**: `PermissionCoordinator.shouldTrustLiveValidationWithoutCoreGraphics(...)` now trusts only fresh request-session state or current-process live validation, while `takePendingCaptureResumeIfFresh()` recreates the recent request session in memory after the one automatic relaunch.

### replayd kickstart blocked by SIP on Tahoe (macOS 26)
- **Mistake:** `launchctl kickstart -k gui/<uid>/com.apple.replayd` was the core "silent repair" mechanism in 3 code paths. On Tahoe with SIP enabled, it fails with `Operation not permitted`.
- **Root cause:** macOS 26 tightened SIP restrictions on restarting system daemons. replayd restart is no longer reliable as a repair strategy.
- **New rule:** Treat replayd restart as best-effort, not a gating step. All callers must proceed to the next recovery action (alert, relaunch, etc.) when repair fails. Log `best_effort=true` for diagnostics.
- **Example:** `handleCapturePermissionFailure` now logs repair failure and proceeds directly to `publishExplicitFailure()` and alert presentation.

### SCK error classification must distinguish systemStoppedStream and missingEntitlements
- **Mistake:** Only `.userDeclined` was classified as permanent; `.systemStoppedStream` and `.missingEntitlements` fell through as generic transient errors. This caused incorrect behavior: system-stopped was incrementing the transient failure counter (wrong — it's recoverable without counting), and missing-entitlements was being retried (wrong — it's permanent).
- **Root cause:** Coarse boolean `isSCKErrorPermanent` only checked one code.
- **New rule:** Use an enum classifier (`ScreenCaptureFailureKind`) with 4 cases. `.systemStopped` = recoverable without incrementing failure counter. `.missingEntitlements` = permanent like `.userDeclined`. `.transient` = everything else, counts toward failure threshold.
- **Example:** `classifySCKError(_:)` returns `.systemStopped` for `SCStreamError.Code.systemStoppedStream` — no failure counter increment, not treated as permission denied.

### Concurrent permission validation must be serialized
- **Mistake:** Overlapping calls to `handleCapturePermissionFailure` / `revalidateAfterSettingsReturn` / `runUserInitiatedValidation` could interleave repairs and alerts, causing duplicate alerts or conflicting state.
- **Root cause:** No guard against concurrent validation flows. Rapid-fire capture failures or user-triggered validation during settings return polling could all run simultaneously.
- **New rule:** Use a single `inFlightValidation: Task<ScreenRecordingState, Never>?` gate. Callers that arrive while another validation is in-flight await the same task's result. Gate clears after completion so sequential calls run independently.
- **Example:** `async let first = coordinator.runUserInitiatedValidation(); async let second = coordinator.runUserInitiatedValidation()` — only one interactive check runs, both get the result.

### Tahoe System Settings deep links changed scheme
- **Mistake:** Used `com.apple.preference.security?Privacy_ScreenCapture` — the pre-Tahoe scheme. On macOS 26, this opens to the wrong pane or fails silently.
- **Root cause:** macOS 26 renamed the privacy pane identifiers.
- **New rule:** Use `com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture` (and `Privacy_Accessibility`) for Tahoe deep links.
- **Example:** `"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"`

### AXIsProcessTrustedWithOptions shows the system prompt; AXIsProcessTrusted does not
- **Mistake:** Used `AXIsProcessTrusted()` which only checks — never prompts. Users had to manually navigate to System Settings when accessibility was denied.
- **Root cause:** `AXIsProcessTrusted()` is a passive check. `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt: true` triggers the system prompt.
- **New rule:** Use `AXIsProcessTrustedWithOptions` for first-denial accessibility prompts. Fall back to manual NSAlert + `openSystemSettings()` only if the user has already been prompted and still denied.
- **Example:** `let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary; return AXIsProcessTrustedWithOptions(options)`

### kAXTrustedCheckOptionPrompt is not concurrency-safe in Swift 6
- **Mistake:** `kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String` fails to compile in Swift 6 strict concurrency — the global is shared mutable state.
- **Root cause:** C globals imported into Swift aren't marked `Sendable`. Swift 6 flags them.
- **New rule:** Use the string literal `"AXTrustedCheckOptionPrompt"` directly instead of the C constant.
- **Example:** `["AXTrustedCheckOptionPrompt": true] as CFDictionary` (not `kAXTrustedCheckOptionPrompt.takeUnretainedValue()`)

## Swift Language

### Extension file splitting
- **Rule**: Change `private` → `internal` when moving methods to extension files. Stored properties must stay in main file. `@MainActor` extensions inherit isolation.

### String.flatMap iterates characters
- **Rule**: Prefer `guard let`/`if let` over chained `.flatMap` on String properties. `String.flatMap` is `Sequence.flatMap` (iterates characters), not `Optional.flatMap`.
- **Example**: `bid.flatMap { ... }` where `bid` is `String` → `bid` param is `Character`. Fix: `guard let bid = app?.bundleIdentifier`.

### OSLogMessage no + concatenation [Graduated]
- **Rule**: Never use `+` inside Logger calls. Extract to local `let` variable, then `logger.info("\(msg, privacy: .public)")`.

### SwiftLanguageMode.v6 requires swift-tools-version 6.0
- **Rule**: Don't add `.v6` to `swiftLanguageVersions` with `swift-tools-version:5.9`. The enum case is gated behind `@available(_PackageDescription 6)`.

## Testing

### Vision framework minimum image size
- **Rule**: `VNRecognizeTextRequest` requires at least 3x3 pixels. Use 10x10+ in tests.

### Method signature changes → grep all dirs [Graduated → MEMORY.md]
- **Rule**: When changing a method signature, grep both source and test directories for all call sites.

### Security fixes invalidate existing tests
- **Rule**: When tightening validation, check existing tests — they may depend on the insecure behavior. Update tests to use valid state, add a test for the rejection path.
- **Example**: S2-16 license bypass fix required adding `licenseKey` to the licensed test.

### Rate-limiting static state needs test isolation
- **Rule**: Make throttle timestamp `internal` (not `private`) and reset in `setUp()`.
- **Example**: `URLSchemeHandler.lastHandledDate = nil` in setUp.

### CGRect normalizes negative dimensions
- **Rule**: Test zero-size guards with `CGRect(width: 0, height: 0)`, not negative values. CGRect auto-normalizes negatives.

### Test temp file paths must include UUID
- **Rule**: Always include `UUID().uuidString` in temp file paths. Files persist between test runs and cause stale state.

### Pipeline statusMessage overwrite
- **Rule**: Don't assert on final `statusMessage` for intermediate errors — later stages overwrite it. Assert on a different signal (e.g., filePath is nil) or collect messages via sink.

## Persistence / Thread Safety

### KeychainHelper deliberately deprecated [Graduated]
- **Rule**: Use `HistoryCrypto.encrypt()` for sensitive persistence, not Keychain.

### DispatchQueue.sync must wrap entire critical section
- **Rule**: For check-then-set logic on shared state, wrap the entire method in `queue.sync {}`, not individual property accesses. TOCTOU race otherwise.
- **Example**: `HistoryCrypto.getOrCreateKey()` runs entirely inside `keyQueue.sync { }`.

### Debounced saves need synchronous flush on termination
- **Rule**: Any class with debounced persistence must expose `saveNow()`. `applicationWillTerminate` must call it.
- **Example**: `AppState.shared.saveHistoryNow()` + `AppSettings.shared.saveAllSettings()`.

### Don't cache failure results in lazy properties
- **Rule**: Only cache successful results. Return failure values without storing, so retries are possible.
- **Example**: `guard let data = try? ... else { return Data() }` — don't set `_pngData` on the failure path.

## Third-Party Libraries

### SPUUpdater delegate must be set at init
- **Rule**: `SPUStandardUpdaterController` takes its delegate only at init. Use a separate `NSObject` delegate proxy, pass at init, wire closures back.
- **Example**: `UpdateDelegateHandler` created first, passed to init, then closures connect to `UpdateManager`.

## Swift Concurrency

### Package.swift swift-tools-version for macOS 26
- **Rule**: macOS 26 requires `swift-tools-version:6.2` in Package.swift. Use `.swiftLanguageMode(.v5)` on targets to avoid Swift 6 strict concurrency errors while still targeting the new SDK.
- **Context**: `.macOS(.v26)` was introduced in PackageDescription 6.2. Earlier tool versions don't recognize it.

### withThrowingTaskGroup nil return types
- **Rule**: When a `withThrowingTaskGroup` closure returns an optional type (e.g., `String?`), annotate the outer variable with explicit type (e.g., `let response: String? = ...`) and use `nil as String?` for typed nil returns. Swift cannot infer optionality from bare `nil`.

### CGWindowListCreateImage removed in macOS 26
- **Rule**: `CGWindowListCreateImage` is unavailable on macOS 26+. Use ScreenCaptureKit (`SCShareableContent` + `SCScreenshotManager`) instead for screen/window capture.

## AI Features Architecture

### Detached task AI processing
- **Rule**: Extract AI post-processing (PII detection, embeddings, metadata) into file-scope helper functions, not class methods on @MainActor types. Avoids Sendable issues when called from `Task.detached`.
- **Example**: `detectPIIIfEnabled()`, `generateEmbeddingIfEnabled()`, `generateSmartMetadataIfEnabled()` as private file-scope functions in CapturePipeline.swift.

### SwiftLint function complexity
- **Rule**: When a pipeline function exceeds complexity limits after adding features, extract logical stages into helper functions. Each stage (PII, embedding, metadata) gets its own function. Use `// swiftlint:disable file_length` and `type_body_length` at file level for naturally large files.

## Process

### Documentation drift
- **Rule**: Archive stale planning material to `tasks/archive/`. Keep only current behavior in live docs. Update docs same-day when flows change.

### Never skip research steps before implementation
- **Rule**: When a plan has a research/validation step before coding (e.g., Codex calls, deep research), complete it first. Even a detailed plan can have wrong assumptions that research would catch.
- **Mistake**: Skipped Codex research calls in the permission fix plan and went straight to implementation. Research later revealed 4 additional gaps (replayd approval cache not cleared on TCC reset, SCK retry window too short, missing sckStateResetter in capture failure handler, blank image detection).
- **Key insight**: Research validates assumptions. The 0-10 second TCC propagation finding changed the retry window from 1.6s to ~7s. The Sequoia replayd `ScreenCaptureApprovals.plist` finding revealed the nuclear reset button was broken.

### 2026-06-10 — Pre-commit swift build fails only under sandboxed git commit [domain: process]
**Mistake:** Assumed hook failure was caused by the staged change; retried commit twice.
**Root cause:** Claude Code Bash sandbox + nested `swift build` resolves /Library/Developer/CommandLineTools SDK (macOS 27 / Swift 6.4) against Xcode 26's Swift 6.2.3 — SDK/compiler mismatch. Direct hook run and direct swift build pass.
**Rule:** If pre-commit swift build fails with "SDK is not supported by the compiler" while `swift build` passes, run the commit with explicit `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` and sandbox disabled. Never --no-verify.
**Confidence:** low (1x)

### 2026-06-11 — Staged files ride along across branch switches [domain: process]
**Mistake:** Failed pre-commit attempts left files staged; switching branches and committing "one file" actually committed the whole stale index (PR #17 absorbed S1).
**Root cause:** git add survives branch switches; `git commit` commits the index, not the named files I had in mind.
**Rule:** After any failed commit + branch switch, run `git status` and `git diff --cached --stat` BEFORE the next commit.
**Confidence:** low (1x)

### 2026-06-11 — Pre-commit hook inherits the caller's env: export SDK workaround before git commit [domain: process]
**Mistake:** Ran `git commit` without `DEVELOPER_DIR`/`SDKROOT` exported; the pre-commit hook's `swift build` picked the CommandLineTools macOS 27 SDK (Swift 6.4) under the Xcode 6.2.3 toolchain and hung ~10 min before failing with "this SDK is not supported by the compiler".
**Root cause:** Git hooks run in the committing shell's environment; the SDK workaround was only applied to explicit build/test commands, not to the commit invocation.
**Rule:** On this machine, prefix `git commit` (and `--amend`) with `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` so hook-run swift build/test use the matching toolchain.
**Confidence:** medium (3-5x) — re-hit 2026-06-11 (task22-salvage): background-shell commit hung on the manifest compile against the CLT SDK; killed and re-ran with env exported.

### 2026-07-01 — Green tests can pass on a 100% non-functional feature that bypasses OS routing [domain: process|swift]
**Mistake:** The `caloura://` URL scheme shipped as ~420 lines of careful, fully-tested handler code — but it never worked in the built app. LaunchServices only routes `scheme://` URLs to an app that declares `CFBundleURLTypes` in Info.plist; Caloura never did (absent from source Info.plist, `project.yml`, and the built `.app`). So `open caloura://…` and browser click-throughs never reached the handler.
**Root cause:** Every test called `URLSchemeHandler.handle(url)` directly, bypassing the OS registration + routing layer entirely. The suite was green on a feature the OS could never invoke. Worse: `codex/CODEMAP.md` documented the scheme as a live entry route, and the in-app token gate only guarded `copy/*` (whose token accessor had zero in-process callers) while `capture/*` was token-free and `autoCopyToClipboard` default-true — a latent unauthenticated-capture foot-gun that a future `CFBundleURLTypes` addition would have armed.
**Rule:** When a feature depends on OS-level registration (URL scheme, share extension, Spotlight, Quick Look, login item), a unit test that calls the internal handler directly proves nothing about reachability. Either add one test that exercises the real registration/routing path, or treat the feature as unverified. If such a subsystem is found dead, delete it — dead *security-sensitive* code is worse than none, because the next reader sees "tested + secure" and re-enables it without redoing the threat analysis. Deleted here (branch `remove-dead-url-scheme`): handler + tests + GetURL registration + CODEMAP claims; 792 tests still pass.
**Confidence:** low (1x)

### 2026-07-01 — Local brew xcodegen (2.42.0) drifts the pbxproj vs pinned CI (2.45.4) [domain: xcodegen|process]
**Mistake:** Regenerated the project with the local `brew` xcodegen out of habit; it emits a different pbxproj/scheme format than the CI-pinned version (24 insertions/12 deletions on the pbxproj, 9 lines on the scheme between 2.42.0 and 2.45.4).
**Root cause:** `brew "xcodegen"` installed an unpinned 2.42.0 locally while `scripts/ci_tool_versions.env` pins `XCODEGEN_VERSION=2.45.4`. xcodegen output is deterministic per (version + project.yml + source tree) but differs *across versions*. With the new L12 drift gate (`xcodegen generate && git diff --exit-code` on pbxproj/scheme/workspacedata), a 2.42.0-generated commit reds out CI on the first run.
**Rule:** Always regenerate with the **pinned** xcodegen, never plain `xcodegen` from PATH. Fetch the pinned artifact (`github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip`, checksum in `ci_tool_versions.env`) and run `…/xcodegen/bin/xcodegen generate`, or `brew upgrade xcodegen` to the pinned version. The gate command (`xcodebuild build && swift test && swiftlint`) does NOT call xcodegen, so running the gate is safe — only explicit `xcodegen generate` reverts the format. Verified pinned output is idempotent + machine-independent (no `/Users/`, no dates, no hostname; objectVersion=77 is per-xcodegen-version, not per-machine). Since 2026-07-01 there is **one source of truth**: `scripts/install_xcodegen.sh` (prints the pinned bin dir); use it instead of hand-fetching.
**Recurrence (2026-07-02):** Did it AGAIN — added new B3 source files mid-session, ran plain `xcodegen generate` (local 2.42.0) out of habit to wire them in, silently reverting the committed pbxproj from objectVersion 77 → 54. Worse, I'd already written docs (`todo.md`, this file) asserting "committed as pinned 2.45.4 / objectVersion 77" from the EARLIER correct regen, and never re-grepped the artifact — so the docs were false vs the working tree, and my own self-review passed it. An independent adversarial reviewer caught it by reading `objectVersion` + `xcodegen --version` directly. **Added sub-rule:** after ANY `xcodegen generate` (esp. to include new files), immediately `grep -m1 objectVersion Caloura.xcodeproj/project.pbxproj` and confirm it's 77 (pinned), not 54 (brew). And NEVER trust a doc's claim about a generated artifact's state at commit time — re-grep the artifact itself. New files can be re-included by running the *pinned* installer's xcodegen, which both wires them in AND keeps the format correct — there is never a reason to reach for PATH xcodegen.
**Confidence:** high (3x — original + leaked-into-scripts variant + this mid-session recurrence)

### 2026-07-01 — Version-bumping a committed *generated* artifact requires pinning the generator in EVERY consumer [domain: xcodegen|process|ci]
**Mistake:** Batch F bumped the committed `Caloura.xcodeproj` to XcodeGen 2.45.4's format (objectVersion 77) and deleted the `Brewfile`, but left `scripts/release_ready.sh` and `scripts/release.sh` running a bare `xcodegen generate` off ambient PATH (local brew 2.42.0 → objectVersion 54). Result: `release_ready.sh` tripped its OWN drift gate on an in-sync project, and `release.sh` (the script that packages the SHIPPED artifact) would regenerate to a stale format — or, on a clean machine with no brew xcodegen, fail with "command not found". Only CI was pinned; the whole local pipeline silently drifted.
**Root cause:** I treated "pin the generator" as a CI concern and fixed only `ci.yml`/`release-smoke.yml`. A committed generated file is byte-sensitive to its generator's version, so EVERY consumer that regenerates it — CI *and* local release scripts — must use the same pinned version. Deleting the Brewfile removed the only thing that had (accidentally) kept local ≈ CI, exposing the gap. A subshell `export PATH=` also doesn't reach a later sibling subshell, so pinning one step doesn't cover a `./release.sh` invoked later.
**Rule:** When you change the pinned version of a tool that regenerates a *committed* artifact (xcodegen, protoc, codegen, etc.), grep for EVERY invocation across scripts + CI + local tooling and route them all through ONE shared pinned installer — don't pin CI and trust PATH locally. After such a bump, run the drift gate from a shell that does NOT have the old tool on PATH to catch the leak. Verify the invariant holds repo-wide (`grep -rn '<tool> generate'` → each site pinned).
**Confidence:** low (1x)

### 2026-07-01 — Flipping a production default silently reroutes a branch that tests depend on [domain: swift|process]
**Mistake:** Changed `autoDetectPII` default `false→true`. `CaptureEnrichmentService.runEnrichment` branches on that flag: OFF calls the injected `recognizeText` mock; ON calls `recognizeTextObservations` (real Vision) + PII detection. 12 pipeline tests mocked only `recognizeText`, inherited the default via the `makePipeline` fixture (fresh `AppSettings(defaults:)` suite), and after the flip silently took the observations branch — their mock never ran (timeouts, wrong phase, and a real macOS `GetE5PathFromCompositeBundle` E5-model error that *looked* environmental).
**Root cause:** The fixture inherited a mutable production default instead of pinning the setting it actually exercised, so a one-line default flip changed the behavior of unrelated tests. The E5 OS-framework error was a red herring produced *because* the code now hit real Vision — I nearly dismissed the failures as environmental. Verified by reading the branch (`runEnrichment` :193-208), not by assuming.
**Rule:** Before flipping a default, grep for every read of that key that *selects a code path* (not just the persisted value) and check which tests inherit it via a fixture. Test fixtures must pin the settings they depend on, never inherit production defaults; fix at the fixture factory when many tests share it (`makePipeline` → `autoDetectPII = false` when it creates the settings), and per-test when a test injects its own settings. When a suite starts failing right after a default flip, suspect the flip before blaming the environment — even when the error text points at the OS.
**Confidence:** low (1x)

### 2026-07-01 — `isKeyWindow` system tests fail from a focused CLI `xcodebuild test` (host not frontmost) [domain: swift|process|ci]
**Mistake:** Ran the full `xcodebuild test` after a Track B feature and got 5 assertion failures across 4 `CalouraSystemTests` methods — rooted in `overlayWindows.filter(\.isKeyWindow).count` being 0 on the capture overlay (area/fullscreen/multiscreen; one method adds a dependent screen-match assertion that fails only because the key set is empty). Looked alarming mid-feature. (First wrote it up as "5 failures, all count==1 assertions" — imprecise: it's 5 assertions / 4 methods, and one is the dependent screen check.)
**Root cause:** `NSWindow.isKeyWindow` is only true when the owning app is the frontmost/active application. `makeKeyAndOrderFront` orders a panel front but it never *becomes key* while another app (the Terminal I launched from) holds focus, so the count is 0. The tests are correct; the local run environment isn't interactive-focused. CI passes because a GHA macOS runner's test host has nothing competing for focus. The one system test not asserting `isKeyWindow` passed.
**Rule:** When only the `isKeyWindow`/key-window assertions fail under a CLI `xcodebuild test`, suspect the focus environment, not the code — but PROVE it, don't assume (per the default-flip lesson). Decisive check: `git diff HEAD` the test file + the coordinator `present()` path + the window class's `canBecomeKey`/`makeKey`/`styleMask`/`level`; if all empty, unchanged code can't have regressed and the failure is environmental. Never "fix" it by weakening the assertion. The per-batch gate (`swift test` + `xcodebuild build` + swiftlint) is the reliable local signal; treat full-suite key-window results as CI's job.
**Confidence:** low (1x)

### 2026-07-02 — `git commit` hook's `swift build` fails ("SDK not supported by the compiler") while the same build passes in-shell [domain: swift|process|ci]
**Mistake:** The pre-commit hook's `swift build` died with `failed to build module 'Swift'; this SDK is not supported by the compiler` (CommandLineTools SDK built with Swift 6.4 vs the active Xcode compiler 6.2.3), blocking the audit commit through four attempts. The identical `swift build` — and running `.git/hooks/pre-commit` directly — passed. I first misdiagnosed it as a stale SwiftPM ModuleCache and blind-retried the commit twice (and once tried pinning `DEVELOPER_DIR`, which did nothing) before instrumenting the actual hook environment. A background task reporting `exit 0` also masked it: the *wrapper* exited 0 while the wrapped `git commit` recorded `COMMIT_EXIT=1` and HEAD never moved.
**Root cause:** Apple's `/usr/bin/git` shim (part of CommandLineTools) injects `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` into every hook subprocess. After a partial toolchain update — CLT bumped to the macOS 27 SDK / Swift 6.4 while the *selected* Xcode stayed 26.2 / Swift 6.2.3 — that injected SDKROOT points at a Swift-version-mismatched SDK. `swiftc` honours `SDKROOT` over `xcode-select`, so the build paired Xcode's compiler with CLT's SDK. Two traps that hid it: `DEVELOPER_DIR` does NOT override `SDKROOT`, and `xcrun --show-sdk-path` ignores `SDKROOT` (it reads `xcode-select`), so every `xcrun`-based diagnostic returned the *correct* Xcode SDK and looked fine. Survives `xcrun --kill-cache` (not a cache issue). My normal Bash shell has `SDKROOT` unset, which is why in-shell builds passed.
**Rule:** When a build passes in a normal shell but fails *only* inside a git hook (or vice-versa), DIFF THE ENVIRONMENT the hook runs in before theorizing — dump `env` from an instrumented hook that `exit 1`s *before* any slow/hanging step (a `swiftc` under a bad `SDKROOT` hangs, not fails-fast; and restore the real hook in a step that can't be skipped by a parent timeout — I nearly left a diagnostic hook installed when my 2-min tool timeout SIGTERM'd mid-run). For Swift pre-commit hooks, normalize the toolchain at the top: `export DEVELOPER_DIR="$(xcode-select -p)"` and `unset SDKROOT` so compiler and SDK come from one toolchain. Diagnose SDK mismatches with `swiftc -v <file>` (shows the real `-sdk`), never `xcrun --show-sdk-path` (blind to `SDKROOT`). Deeper fix is the user's: update Xcode to match CommandLineTools (both 6.4/27.0) — the hook fix only makes local commits robust to the lag. And: a background wrapper's `exit 0` ≠ the wrapped command succeeded — assert on `COMMIT_EXIT`/HEAD movement, not the wrapper.
**Confidence:** medium (fresh, but multi-trap and machine-wide — affects every Swift repo on this Mac with a `swift build` hook until Xcode catches up)
