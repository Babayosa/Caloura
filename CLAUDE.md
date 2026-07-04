# Caloura — Project-Specific Rules

Inherits global rules from `~/CLAUDE.md`.

## Build & Test

- **Build**: `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
- **Test**: `swift test`
- **Lint**: `swiftlint lint --quiet`
- Always run all three before marking a task done.

### Test-target split (important)

`swift test` runs **only** the SwiftPM `CalouraTests` unit target. The
`CalouraSystemTests` (capture/overlay/cursor system regression guards, incl. the
"crosshair-gone-forever" guards) and `CalouraUITests` targets are declared only in
`project.yml`, not `Package.swift`, so they run **only** under `xcodebuild test`:

```
"$(scripts/install_xcodegen.sh)/xcodegen" generate && xcodebuild test -project Caloura.xcodeproj \
  -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -destination 'platform=macOS'
```

Never plain `xcodegen` from PATH — brew 2.42.0 silently reverts the committed pbxproj
(objectVersion 77 → 54) and reds out the CI drift gate; `install_xcodegen.sh` prints the pinned
2.45.4 bin dir on stdout. After any generate: `grep -m1 objectVersion Caloura.xcodeproj/project.pbxproj` must show 77.

`CalouraTests/UITests/` (perf/filter unit tests) is a subdirectory of the *unit*
target and does run under `swift test` — distinct from the top-level `CalouraUITests`
XCUITest target. CI runs unit + system on every PR; `scripts/release_ready.sh` runs the
full gate including the UI smoke target.

## Release Pipeline

- **Full publish**: `./scripts/publish.sh <version>` — builds, notarizes, signs appcast, pushes to GitHub Pages
- **Build only**: `./scripts/release.sh <version>` — builds + notarizes, outputs `build/Caloura-<version>.zip`
- **Publish only (skip build)**: `SKIP_BUILD=1 ./scripts/publish.sh <version>`
- Site repo: `~/caloura-site` (GitHub Pages, `Babayosa/caloura-site`)
- `sign_update` at `.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`
- Site `release.sh` uses `sed 'r'` with temp file for XML insertion (not `sed 'a'`)

## Project Conventions

The rules below are the terse invariants. Expanded procedures, code templates, and a
failure-symptom index live in the **swift-macos-integration** skill
(`~/.claude/skills/swift-macos-integration/SKILL.md`) — invoke it before touching
TCC/permission, cursor, overlay, or stateful-flag code.

- Don't stash runtime data (license state, app state, history) in the Keychain — persist it on disk, and encrypt sensitive history via `HistoryCrypto.encrypt()` (AES-GCM). The Keychain holds exactly one item: HistoryCrypto's non-interactive, device-only AES root key. Don't add new Keychain items.
- Treat `CGPreflightScreenCaptureAccess()` as a coarse passive signal only; after an explicit Screen Recording grant attempt, trust live ScreenCaptureKit validation before falling back to repair or relaunch
- `CGWindowListCopyWindowInfo` gives false positives — never use for permission checks
- `NSCursor.hide()/unhide()` are reference-counted — must balance exactly
- Use `NSCursor.push()`/`pop()`, not `.set()` — the cursor rect system overrides `.set()`
- Never use `disableCursorRects()` if you need `addCursorRect`
- NSApp.activate() cursor race: layered defense (push + cursorRects + cursorUpdate + didBecomeActive + mouseMoved)
- Capture overlays use `NSPanel` with `.nonactivatingPanel` — never `NSApp.activate` before showing them (hides other apps' windows)
- Cursor controller state must be recoverable: every coordinator entry calls `resetCursorState()` before `beginCrosshairSession()`, and `CaptureOverlayWindowPool.release()`/`tearDown()` call `resetCursorState()` as a safety net. `beginCrosshairSession` stays idempotent — recovery is a separate explicit operation.
- Stateful flags require recovery API + diagnostic log + defer-based clear. Any boolean presentation flag or in-flight Task slot set before an `await` must be cleared with `defer { flag = false/nil }`, never with a manual paired assignment after the await (cancellation/throw leaks it). Any guard like `guard !flag else { return }` needs a separate explicit recovery API and a `.debug` log line on the early-return so leaked state is observable. Failure paths need a discrete `*Phase`/enum case + `statusMessage` + `OSLog` line — never swallow an error into an optional. See `tasks/lessons.md` "State Machines / Recovery".
- `AreaCaptureSessionCoordinator.present()` and `FullscreenCaptureSessionCoordinator.present()` MUST call `beginCrosshairSession()` BEFORE any `makeKeyAndOrderFront` / `orderFrontRegardless`. `becomeKey()` fires synchronously inside `makeKeyAndOrderFront`, and `primeCrosshair()`'s `scheduleReprime()` silently no-ops if `cursorActive` is still false.
- `OSLogMessage` does NOT support `+` concatenation — extract to local `let` variable first
- replayd restart (`launchctl kickstart`) is best-effort on Tahoe — SIP blocks it. Callers must never gate on repair success.
- System Settings deep links: `com.apple.settings.PrivacySecurity.extension?Privacy_*` (not `com.apple.preference.security`)
- Use `AXIsProcessTrustedWithOptions` with `"AXTrustedCheckOptionPrompt": true` for accessibility prompts (not `AXIsProcessTrusted()`)
- SCK errors: use `classifySCKError` enum — `.systemStoppedStream` is recoverable, `.missingEntitlements` is permanent

## Lessons

See `tasks/lessons.md` for detailed lessons with examples.
