# Caloura — Codex Agent Rules

## Build & Validate

Run in this order. All must pass before commit.
1. `swift build`
2. `swiftlint lint --quiet`
3. `swift test` — full suite, no skipping, no deleting tests

## Branch Protocol
1. Create branch: `task-XX-[short-description]`
2. All work on this branch. Never commit directly to main.
3. Commit format: `[task-XX] Short description of change`
4. One commit per task (squash if needed). Push to remote.

## Code Standards
- Reduce code, don't add unnecessarily. Refactor before writing new functions.
- Follow existing patterns. Don't introduce new paradigms.
- No commented-out code. Delete what you don't need.
- No TODO comments without a linked task number.

## Architecture
- No Keychain for runtime persistence — use `HistoryCrypto.encrypt()` instead
- `CGPreflightScreenCaptureAccess()` = coarse passive signal only; after explicit grant attempt, trust live ScreenCaptureKit validation
- `CGWindowListCopyWindowInfo` gives false positives — never use for permission checks
- `NSCursor.hide()/unhide()` are reference-counted — must balance exactly
- Use `NSCursor.push()`/`pop()`, not `.set()` — cursor rect system overrides `.set()`
- Capture overlays use `NSPanel` with `.nonactivatingPanel` — never `NSApp.activate` before showing
- `OSLogMessage` does NOT support `+` concatenation — extract to local `let` first

## Safety
- NEVER add lint suppression comments. Fix the actual issue.
- NEVER fabricate fallbacks, swallow errors, or weaken tests to pass.
- Before changing any method signature, grep ALL directories (source + tests) for call sites.

## If Validation Fails
1. STOP. Do not commit broken code.
2. Attempt fix (max 2 retries).
3. If still failing, create `task-XX-BLOCKED.md` with: what failed, what you tried, root cause hypothesis.
4. Do NOT proceed to next task.

## Forbidden Actions
- Deleting or skipping tests to make them pass
- Modifying AGENTS.md
- Working on multiple tasks in one session
- Making changes outside the task scope
