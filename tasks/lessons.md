# Lessons Learned

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

## 2026-02-05: OSLogMessage does not support String concatenation with `+`

- **Mistake**: When wrapping long `logger.info()` / `logger.error()` calls to fix `line_length` SwiftLint warnings, used `+` to split strings: `logger.info("part1 " + "part2")`. This compiles with regular `String` but fails with `OSLogMessage`.
- **Root cause**: Swift `os.Logger` methods accept `OSLogMessage`, which conforms to `ExpressibleByStringInterpolation` but NOT `ExpressibleByStringConcatenation`. The `+` operator produces a `String`, not an `OSLogMessage`. The compiler error is: `cannot convert value of type 'String' to expected argument type 'OSLogMessage'`.
- **Rule**: Never use `+` inside Logger calls. To break long logger lines: (1) extract values into local variables before the call, (2) use a single string literal with `\()` interpolation, or (3) build a `String` variable first, then pass it as `logger.info("\(msg, privacy: .public)")`.
- **Example**: `logger.error("Failed to decode \(source): \(desc). " + "Attempting recovery.")` fails. Fix: `let errMsg = "Failed to decode \(source): \(desc). Attempting recovery."` then `logger.error("\(errMsg)")`.
