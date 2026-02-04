# Task 02: Public Download QA Script Updates

## Objective
Align `scripts/public_download_qa.sh` with current Caloura runtime behavior (v1.0.6): no runtime keychain dependency and file-backed encrypted history.

## Context
- Depends on: task-01
- Blocking: reliable public artifact QA without stale assumptions

## Specification
- Update `scripts/public_download_qa.sh`:
  - Require explicit `--version` for commands that touch public artifacts (avoid stale defaults).
  - Clean-room reset must remove file-backed history state under:
    - `~/Library/Application Support/Caloura/history.enc`
    - `~/Library/Application Support/Caloura/security/history.key`
  - Replace keychain snapshots with storage snapshots for the above files (existence + permissions).
  - Keep legacy keychain deletion as best-effort cleanup only (no longer a success signal).
  - Add an option to keep quarantine attributes for Gatekeeper validation (`KEEP_QUARANTINE=1`).
  - Update `manual-checks` text to reflect file-backed history expectations.
- Update `tasks/public-download-qa-runbook.md` if script usage/output changes.
- Run required validations: `swift build`, `swiftlint`, `swift test`.

## Acceptance Criteria
- [ ] Script no longer defaults to a hard-coded version (forces explicit `--version` for relevant commands).
- [ ] Clean-room reset removes file-backed history state.
- [ ] Script prints storage snapshots (history payload/key paths + permissions).
- [ ] `manual-checks` content matches current architecture (file-backed history, no keychain prompts).
- [ ] `swift build`, `swiftlint`, `swift test` pass.
- [ ] Task 02 evidence recorded in `tasks/todo.md` and summary recorded in `codex/CONTEXT-CHAIN.md`.

## Notes
- Keep scope limited to release confidence + QA tooling; no app runtime behavior changes.
