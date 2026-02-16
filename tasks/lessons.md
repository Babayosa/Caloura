# Lessons Learned — Caloura

<!-- Organized by topic. Graduated entries have rules in CLAUDE.md; detail kept here as reference. -->
<!-- When a lesson's rule is added to CLAUDE.md, mark it [Graduated] and trim to rule-only. -->

## AppKit / Cursor

### NSCursor.hide/unhide imbalance [Graduated]
- **Rule**: Guard `NSCursor.hide()` behind `window != nil` in `viewDidMoveToWindow()`. Use a boolean flag to balance hide/unhide exactly.
- **Context**: `viewDidMoveToWindow` fires on both add (`window != nil`) and remove (`window == nil`). Unguarded hide on removal creates a permanent imbalance.

### NSCursor.set() vs push/pop [Graduated]
- **Rule**: Use `NSCursor.crosshair.push()` to enter custom cursor mode, `NSCursor.pop()` to leave. Never use `.set()` — the cursor rect system overrides it asynchronously.

### NSApp.activate() cursor race [Graduated]
- **Rule**: Never use `disableCursorRects()` if you need `addCursorRect`. Use layered defense: (1) push in viewDidMoveToWindow, (2) addCursorRect, (3) cursorUpdate override, (4) didBecomeActiveNotification one-shot, (5) mouseMoved override.
- **Context**: `disableCursorRects()` kills ALL cursor rect processing — the crosshair never appears. Each layer catches a different async timing edge case during `NSApp.activate()`.

## Permissions / macOS

### CGWindowList false positive on Sequoia [Graduated]
- **Rule**: Never use `CGWindowListCopyWindowInfo` as a permission check. `CGPreflightScreenCaptureAccess()` is the only reliable signal.
- **Context**: Sequoia returns window metadata (names, owners) without screen recording permission.

### CODE_SIGNING_ALLOWED=NO strips TCC [Graduated]
- **Rule**: Only use `CODE_SIGNING_ALLOWED=NO` for CI/headless builds. Manual testing requires code signing for TCC permissions.

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
