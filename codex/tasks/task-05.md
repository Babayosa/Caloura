# Task 05: Release 1.0.7 (Public Update)

## Objective
Produce and publish the 1.0.7 release using the current release flow (archive, notarize, package, and public update).

## Context
- Depends on: task-04
- Blocking: none

## Specification
- Update version references to 1.0.7 where user-facing docs/runbooks reference the release version:
  - `README.md`
  - `plan.md`
  - `tasks/public-download-qa-runbook.md`
- Run required validation commands:
  - `swift build`
  - `swiftlint`
  - `swift test`
- Run full release flow:
  - `./scripts/release.sh 1.0.7`
- Publish update:
  - Upload `build/Caloura-1.0.7.zip` to Gumroad (current flow).
  - Update Sparkle appcast via `generate_appcast` (current flow) and publish appcast.
- Run public download verification (post-upload):
  - `scripts/public_download_qa.sh --version 1.0.7 verify`
- Update documentation evidence:
  - `tasks/todo.md`
  - `codex/CONTEXT-CHAIN.md`

## Acceptance Criteria
- [ ] User-facing docs reference version 1.0.7.
- [ ] `swift build`, `swiftlint`, `swift test` pass.
- [ ] `./scripts/release.sh 1.0.7` completes and produces `build/Caloura-1.0.7.zip`.
- [ ] Public artifact is live and `scripts/public_download_qa.sh --version 1.0.7 verify` succeeds.
- [ ] `tasks/todo.md` and `codex/CONTEXT-CHAIN.md` updated with Task 05 evidence.

## Notes
If publish steps are blocked by missing credentials or access, record the blocker and stop.
