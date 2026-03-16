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
