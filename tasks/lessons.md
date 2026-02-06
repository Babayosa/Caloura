# Lessons Learned

## 2026-02-05: Never use CODE_SIGNING_ALLOWED=NO when launching the app for manual testing

- **Mistake**: Built with `CODE_SIGNING_ALLOWED=NO` to launch Caloura for manual cursor testing. The app had no code signature, so macOS couldn't match it to the existing screen capture permission grant — resulting in a permission error on launch.
- **Root cause**: macOS ties screen capture (and other TCC) permissions to the app's code signature identity. `CODE_SIGNING_ALLOWED=NO` strips the signature, making the app appear as a new unsigned binary with no permissions.
- **Rule**: Only use `CODE_SIGNING_ALLOWED=NO` for CI/test builds that don't need runtime permissions. When building to launch and manually test, always build WITH code signing (omit the flag entirely). The command is: `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
- **Example**: `CODE_SIGNING_ALLOWED=NO` → permission denied on area capture. Remove the flag → app launches with existing permissions intact.

## 2026-02-05: Vision framework rejects images smaller than 3x3

- **Mistake**: Wrote an OCR test using a 1x1 black image. Vision threw "The image is too small in at least one dimension 2 x 2 (each dimension has to be more than 2 pixels)".
- **Root cause**: VNRecognizeTextRequest requires images to be at least 3x3 pixels.
- **Rule**: When writing OCR tests with minimal images, use at least 10x10 to stay safely above Vision's minimum.
- **Example**: `makeSolidBlackImage(width: 10, height: 10)` instead of `(width: 1, height: 1)`.

## 2026-02-05: Changing method signature to throws requires updating ALL call sites including tests

- **Mistake**: Changed `ImageProcessor.pngRepresentation(of:)` from `-> Data` to `throws -> Data` but initially missed test files and `CalouraApp.swift` call sites, causing build failures.
- **Root cause**: Only checked main source with grep but forgot test files are compiled separately and have their own call sites.
- **Rule**: When changing a method signature, grep both `Caloura/` and `CalouraTests/` directories for all call sites before running build.
- **Example**: `grep -r "ImageProcessor.pngRepresentation" Caloura/ CalouraTests/`

## 2026-02-05: SPUUpdater delegate can only be set at init time

- **Mistake**: Attempted to set `updaterController.updater.delegate = self` and `updaterController.updaterDelegate = self` after initialization. Neither property exists as a settable Swift property.
- **Root cause**: `SPUUpdater` takes its delegate only via its designated initializer parameter. `SPUStandardUpdaterController`'s `updaterDelegate` is an ObjC ivar (IBOutlet), not a property — it's not exposed to Swift.
- **Rule**: When using `SPUStandardUpdaterController`, the delegate must be passed at init. Since `self` isn't available before `super.init()`, use a separate `NSObject` subclass as the delegate proxy, pass it at init, then wire closures back to the manager.
- **Example**: `UpdateDelegateHandler` (NSObject, SPUUpdaterDelegate) is created first, passed to `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)`, then closures connect it to `UpdateManager`.

## 2026-02-02: CGWindowList false positive on macOS Sequoia

- **Mistake**: Used `CGWindowListCopyWindowInfo` as a fallback permission signal. It returned named windows from other apps even when screen recording permission was denied on Sequoia.
- **Root cause**: macOS Sequoia changed the behavior of `CGWindowListCopyWindowInfo` — it now returns window metadata (names, owner names) without screen recording permission. This was undocumented.
- **Rule**: Never use `CGWindowListCopyWindowInfo` as a permission check. `CGPreflightScreenCaptureAccess()` is the only reliable OS-level permission signal. SCK's `SCShareableContent` is the authoritative functional check.
- **Example**: `hasAnyPermissionSignal()` returned `true` (from CGWindowList showing 4 named windows) even though both CGPreflight and SCK said no permission. This let capture proceed through CG fallback, which silently produced wallpaper-only screenshots.

## 2026-02-02: NSCursor.hide/unhide imbalance from viewDidMoveToWindow

- **Mistake**: Called `NSCursor.hide()` unconditionally in `viewDidMoveToWindow()`. This method fires both when a view is added to a window (`window != nil`) and removed from one (`window == nil`). The extra hide during removal created an imbalance — more hides than unhides — leaving the cursor permanently hidden.
- **Root cause**: `NSCursor.hide()`/`unhide()` use a reference count. Each hide increments, each unhide decrements. Calling hide on window removal doubled the count, but `removeFromSuperview()` (the only unhide site) was called at most once — and sometimes not at all when `NSWindow.close()` doesn't tear down the view hierarchy.
- **Rule**: Always guard `NSCursor.hide()` behind `window != nil` in `viewDidMoveToWindow()`. Use a boolean flag to ensure each instance's hide/unhide calls are exactly balanced. Provide unhide in both `viewDidMoveToWindow(nil)` and `removeFromSuperview()` as belt-and-suspenders.
- **Example**: After an area capture, the overlay windows were closed via `w.close()`. `viewDidMoveToWindow()` fired again during deallocation with `window == nil`, calling `NSCursor.hide()` a second time. The cursor stayed hidden in all subsequent windows (history, preferences, etc.).

## 2026-02-02: String.flatMap iterates characters, not Optional.flatMap

- **Mistake**: Wrote `bundleIdentifier.flatMap { bid in ... }` expecting `Optional<String>.flatMap`. Because `bundleIdentifier` was accessed through optional chaining that resolved to `String` (not `String?`), Swift called `String.flatMap` which iterates characters. The closure parameter `bid` was `Character`, not `String`.
- **Root cause**: Optional chaining (`app?.bundleIdentifier`) returns `String?`, but inside a closure where the optional was already unwrapped, the result was `String`. `String.flatMap` iterates characters (it's `Sequence.flatMap`).
- **Rule**: When converting an optional property to another optional, prefer explicit `guard let` / `if let` over chained `flatMap`. It's clearer and avoids the `String.flatMap` trap.
- **Example**: `window.owningApplication?.bundleIdentifier.flatMap { bid in NSRunningApplication.runningApplications(withBundleIdentifier: bid) }` — `bid` was `Character`. Fixed by using `guard let bid = window.owningApplication?.bundleIdentifier else { return nil }`.

## 2026-02-05: KeychainHelper deliberately deprecated — don't reintroduce

- **Context**: Audit recommended storing license key in Keychain instead of UserDefaults.
- **Discovery**: `KeychainHelper` is explicitly marked "Deprecated runtime helper" with comment "New runtime persistence must not depend on Keychain" — the project deliberately moved away from Keychain to avoid startup authentication prompts.
- **Rule**: Use `HistoryCrypto.encrypt()` for sensitive data persistence, not Keychain. Check project conventions before applying generic security recommendations.
- **Example**: License key now encrypted with AES-256-GCM via HistoryCrypto before storing in UserDefaults. `decryptLicenseKey()` handles both encrypted (Data) and legacy plaintext (String) formats.

## 2026-02-05: DispatchQueue.sync for thread safety must wrap entire critical section

- **Mistake**: Initially added property-level sync (get/set) on `cachedKey` but this doesn't protect the check-then-set pattern in `getOrCreateKey()`.
- **Root cause**: Read-check-write (if nil → load/create → cache) is a TOCTOU race. Protecting individual reads/writes doesn't make the compound operation atomic.
- **Rule**: When a method has check-then-set logic on shared state, wrap the entire method body in `queue.sync {}`, not just individual property accesses.
- **Example**: `HistoryCrypto.getOrCreateKey()` now runs entirely inside `keyQueue.sync { }`.

## 2026-02-04: Documentation drift created contradictory product behavior

- **Mistake**: Kept active docs with mixed historical states (keychain-required vs no-keychain runtime, 4-step onboarding vs current 2-step flow), which caused confusion during release validation.
- **Root cause**: Historical planning/status notes were maintained in-place instead of being archived, so outdated guidance remained in canonical docs.
- **Rule**: Archive stale planning/todo material into `tasks/archive/` and keep only current behavior in live docs (`README.md`, `plan.md`, runbooks). Every permission/auth flow change must include same-day doc updates.
- **Example**: Legacy notes referenced `1.0.5` and a 4-step onboarding model while shipped `1.0.6` uses a 2-step flow with `Grant Permission` + `Check Again` and auto-check feedback.

## 2026-02-05: NSCursor.set() loses to cursor rect system — use push/pop

- **Mistake**: Used `NSCursor.crosshair.set()` to show crosshair during overlay, then `NSCursor.arrow.set()` on completion. The cursor rect system asynchronously reasserted the crosshair after `set()`, causing the crosshair to persist after mouse release.
- **Root cause**: `NSCursor.set()` is a momentary override. The cursor rect system (from `resetCursorRects`/`addCursorRect`) recalculates and reasserts its cursor asynchronously — even after `orderOut`/`close`. Adding `selectionComplete` flags, `ignoresMouseEvents`, `orderOut(nil)` were all fighting the rect system and losing.
- **Rule**: Use `NSCursor.crosshair.push()` when entering a custom cursor mode and `NSCursor.pop()` when leaving. This works with the cursor stack instead of against the cursor rect system. Keep `resetCursorRects`/`addCursorRect` for the declarative API. Don't use `.set()` as manual reinforcement.
- **Example**: `viewDidMoveToWindow` → `NSCursor.crosshair.push()` (only when `window != nil`). `mouseUp` (valid selection) → `NSCursor.pop()`. `keyDown` (Escape) → `NSCursor.pop()`.

## 2026-02-05: OSLogMessage does not support String concatenation with `+`

- **Mistake**: When wrapping long `logger.info()` / `logger.error()` calls to fix `line_length` SwiftLint warnings, used `+` to split strings: `logger.info("part1 " + "part2")`. This compiles with regular `String` but fails with `OSLogMessage`.
- **Root cause**: Swift `os.Logger` methods accept `OSLogMessage`, which conforms to `ExpressibleByStringInterpolation` but NOT `ExpressibleByStringConcatenation`. The `+` operator produces a `String`, not an `OSLogMessage`. The compiler error is: `cannot convert value of type 'String' to expected argument type 'OSLogMessage'`.
- **Rule**: Never use `+` inside Logger calls. To break long logger lines: (1) extract values into local variables before the call, (2) use a single string literal with `\()` interpolation, or (3) build a `String` variable first, then pass it as `logger.info("\(msg, privacy: .public)")`.
- **Example**: `logger.error("Failed to decode \(source): \(desc). " + "Attempting recovery.")` fails. Fix: `let errMsg = "Failed to decode \(source): \(desc). Attempting recovery."` then `logger.error("\(errMsg)")`.

## 2026-02-05: Security fix tests must reflect the new behavior

- **Mistake**: The S2-16 license bypass fix caused `testActivationState_licensed` to fail because the test set `isLicenseActivated = true` without providing a `licenseKey`. The new code correctly revokes licenses with empty keys, but the test didn't account for this.
- **Root cause**: Existing tests assumed the old (buggy) behavior where an empty key + activated flag was a valid state.
- **Rule**: When fixing a security bug that tightens validation, always check existing tests — they may depend on the insecure behavior. Update tests to set up valid state, and add a new test that explicitly validates the fix rejects the insecure path.
- **Example**: Added `settings.licenseKey = "XXXXXXXX-..."` to the licensed test, and added `testActivationState_licensed_emptyKeyRevokes` that verifies the S2-16 fix.

## 2026-02-05: Rate-limiting static state needs test isolation

- **Mistake**: Adding URL scheme rate limiting (S2-3) with a static `lastHandledDate` property would have broken 24 existing URL scheme tests that fire requests in rapid succession.
- **Root cause**: Static state persists between test cases. A 0.5s throttle means only the first test in the suite would actually process its URL — all subsequent tests would be throttled and silently pass without testing anything.
- **Rule**: When adding rate-limiting or throttling with static state, make the timestamp property `internal` (not `private`) and reset it in the test suite's `setUp()`. This keeps production behavior correct while allowing tests to bypass the throttle.
- **Example**: `URLSchemeHandler.lastHandledDate = nil` in `setUp()` resets the throttle before each test.

## 2026-02-05: CGRect normalizes negative width/height — cannot test negative dimensions

- **Mistake**: Wrote a test expecting `CGRect(x: 50, y: 50, width: -10, height: -10)` to have negative width/height. CGRect auto-normalizes to `CGRect(x: 40, y: 40, width: 10, height: 10)`, so the guard `rect.width > 0` passed and the code proceeded to the permission check instead of throwing.
- **Root cause**: `CGRect` stores its origin and size such that `width` and `height` always return positive values. Negative values in the initializer shift the origin and invert the sign.
- **Rule**: When testing boundary conditions on CGRect dimensions, test with zero values (which remain zero after normalization), not negative values. CGRect makes negative-dimension rects impossible at the API level.
- **Example**: Use `CGRect(x: 50, y: 50, width: 0, height: 0)` to test the zero-size guard, not `CGRect(x: 50, y: 50, width: -10, height: -10)`.

## 2026-02-05: SwiftLanguageMode.v6 requires swift-tools-version 6.0

- **Mistake**: Tried to add `.v6` to `swiftLanguageVersions` in Package.swift while the manifest header was `swift-tools-version:5.9`. Build failed with "'v6' is unavailable".
- **Root cause**: The `.v6` enum case in `SwiftLanguageMode` is gated behind `@available(_PackageDescription 6)`. It only exists when the manifest declares `swift-tools-version:6.0` or later.
- **Rule**: Do not add `.v6` to `swiftLanguageVersions` unless the package manifest is upgraded to `swift-tools-version:6.0`. This is a larger migration (new default concurrency semantics, sendability requirements) and should be its own task.
- **Example**: `swiftLanguageVersions: [.v5, .v6]` with `swift-tools-version:5.9` fails. Must first bump to `swift-tools-version:6.0`.

## 2026-02-06: Debounced saves need synchronous flush on app termination

- **Mistake**: Both `AppState` (500ms) and `AppSettings` (300ms) use debounced persistence — `Task.sleep` before writing. If the app quits during that window, the last change is lost silently.
- **Root cause**: `applicationWillTerminate` was never implemented. The debounce pattern assumed the app would always stay running long enough for the sleep to complete.
- **Rule**: Any class with debounced persistence must expose a synchronous `saveNow()` / `saveAllSettings()` method, and `applicationWillTerminate` must call it for every such class.
- **Example**: Added `applicationWillTerminate` calling `AppState.shared.saveHistoryNow()` and `AppSettings.shared.saveAllSettings()`.

## 2026-02-06: Don't cache failure results in lazy-computed properties

- **Mistake**: `ProcessedScreenshot.pngData` and `tiffData` cached `Data()` (empty) on encoding failure. This meant subsequent accesses returned empty data without retrying — leading to 0-byte files written to disk.
- **Root cause**: The fallback `?? Data()` was inside the caching block, so the empty result was stored in `_pngData`/`_tiffData` permanently.
- **Rule**: When using lazy-cache patterns (check cache → compute → store → return), only cache successful results. Return the failure value without caching to allow retry.
- **Example**: `guard let data = try? ... else { return Data() }` without `_pngData = data` on the failure path.

## 2026-02-06: Test temp file paths must be unique per invocation

- **Mistake**: Used `FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-test-\(testName).json")` for `AppState`'s `historyStoreURL` in tests. The file persisted between test runs, so `AppState.init` loaded stale history and the test assertion `count == 0` failed.
- **Root cause**: `AppState.init(historyStoreURL:)` loads history from disk if the file exists. Temp files survive test runs.
- **Rule**: Always include `UUID().uuidString` in temp file paths used for test isolation. This guarantees a fresh file on every test invocation.
- **Example**: `appendingPathComponent("pipeline-test-\(testName)-\(UUID().uuidString).json")`

## 2026-02-06: Pipeline statusMessage gets overwritten by later stages

- **Discovery**: `processCapture` sets `statusMessage = "Save failed: ..."` on disk error, but `distributeCapture` immediately overwrites it with `"Captured!"`. The save failure message is never visible to the user.
- **Impact**: Minor — the save error is logged. But the user sees "Captured!" even when the file wasn't saved.
- **Rule**: When testing intermediate statusMessage values in a multi-stage pipeline, either (a) assert on a different signal (e.g., filePath is nil), or (b) collect all messages via a sink closure. Don't assert on the final statusMessage for intermediate errors.
- **Follow-up**: Consider whether `distributeCapture` should preserve error messages from prior stages.

## 2026-02-06: NSApp.activate() cursor race requires layered defense, not disableCursorRects

- **Mistake**: Used `disableCursorRects()` on the overlay window to prevent AppKit from resetting the cursor during async activation. This completely broke the crosshair — it never appeared at all.
- **Root cause**: `disableCursorRects()` disables ALL cursor rect processing for the window. The cursor rect system is what normally applies the crosshair via `addCursorRect`. Without it, `push()` alone isn't enough — AppKit doesn't know what cursor to show for that window.
- **Rule**: Never use `disableCursorRects()` if you depend on `resetCursorRects`/`addCursorRect` to set your cursor. Instead, use a layered defense:
  1. `NSCursor.crosshair.push()` in `viewDidMoveToWindow` (immediate)
  2. `resetCursorRects` with `addCursorRect` (declarative)
  3. `cursorUpdate(with:)` override calling `.set()` (rect recalculation events)
  4. `didBecomeActiveNotification` one-shot observer calling `.set()` (catches activation race)
  5. `mouseMoved(with:)` override calling `.set()` (ultimate safety net, Firefox/Mozilla pattern)
- **Example**: `CaptureOverlayWindow.showOnAllScreens()` adds a one-shot `didBecomeActiveNotification` observer that calls `NSCursor.crosshair.set()` when activation completes. `RegionSelectionView` overrides both `cursorUpdate` and `mouseMoved` to force crosshair.
