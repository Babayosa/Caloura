# Codex Execution Rules

## Work Modes

### Release / Task Mode
Use this mode by default for audit fixes, production hardening, release prep,
security, permissions, capture behavior, or any user-requested task.
- One scoped task per branch.
- Full validation is required before commit.
- Update `codex/CONTEXT-CHAIN.md` when behavior changes.

### Exploration Mode
Use this mode only when the user explicitly asks to override the strict task
rules, prototype, investigate, or continue across related findings.
- Multiple related edits are allowed in one session.
- Partial validation is acceptable during iteration if reported honestly.
- Do not commit until scope is narrowed and Release / Task Mode validation
  passes.
- Keep unrelated work out of scope.
- Promote proven exploration results into one or more formal tasks before
  release or commit.

## Branch Protocol
1. Create a new branch: `task-XX-[short-description]`
2. All work happens on this branch
3. Never commit directly to main

## Code Standards
1. Reduce code, don't add unnecessarily. Refactor before writing new functions.
2. Follow existing patterns in the codebase. Don't introduce new paradigms.
3. No commented-out code. Delete what you don't need.
4. No TODO comments without a linked task number.

## Validation (Required Before Commit)
Run in this order. All must pass.
1. `swift build` 
2. `swiftlint`
3. `swift test` — full suite, no skipping, no deleting tests

## If Validation Fails
1. STOP. Do not commit broken code.
2. Attempt fix (max 2 retries).
3. If still failing after retries, create `task-XX-BLOCKED.md` explaining:
   - What failed
   - What you tried
   - Your hypothesis for the root cause
4. Do NOT proceed to next task.

## Commit Protocol
1. Commit message format: `[task-XX] Short description of change`
2. One commit per task (squash if needed)
3. Push to remote

## Documentation
1. Update relevant README or docs if behavior changes
2. Update CONTEXT-CHAIN.md with what you changed

## Forbidden Actions
- Deleting or skipping tests to make them pass
- Modifying RULES.md unless the user explicitly asks to change project rules
- Working on multiple tasks in one session unless the user explicitly invokes
  Exploration Mode or overrides the strict task rules
- Making changes outside the task scope
