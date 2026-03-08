# Caloura — Project-Specific Rules

Inherits global rules from `~/CLAUDE.md`.

## Build & Test

- **Build**: `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`
- **Test**: `swift test`
- **Lint**: `swiftlint lint --quiet`
- Always run all three before marking a task done.

## Release Pipeline

- **Full publish**: `./scripts/publish.sh <version>` — builds, notarizes, signs appcast, pushes to GitHub Pages
- **Build only**: `./scripts/release.sh <version>` — builds + notarizes, outputs `build/Caloura-<version>.zip`
- **Publish only (skip build)**: `SKIP_BUILD=1 ./scripts/publish.sh <version>`
- Site repo: `~/caloura-site` (GitHub Pages, `Babayosa/caloura-site`)
- `sign_update` at `.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`
- Site `release.sh` uses `sed 'r'` with temp file for XML insertion (not `sed 'a'`)

## Project Conventions

- No Keychain for runtime persistence — use `HistoryCrypto.encrypt()` instead
- `CGPreflightScreenCaptureAccess()` is the only reliable permission check on Sequoia
- `CGWindowListCopyWindowInfo` gives false positives — never use for permission checks
- `NSCursor.hide()/unhide()` are reference-counted — must balance exactly
- Use `NSCursor.push()`/`pop()`, not `.set()` — the cursor rect system overrides `.set()`
- Never use `disableCursorRects()` if you need `addCursorRect`
- NSApp.activate() cursor race: layered defense (push + cursorRects + cursorUpdate + didBecomeActive + mouseMoved)
- Capture overlays use `NSPanel` with `.nonactivatingPanel` — never `NSApp.activate` before showing them (hides other apps' windows)
- `OSLogMessage` does NOT support `+` concatenation — extract to local `let` variable first

## Lessons

See `tasks/lessons.md` for detailed lessons with examples.
