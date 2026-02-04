# Task 00: Release Confidence Loop + SwiftPM Validation

## Objective
Ship the release-confidence loop (guardrails + QA + perf evidence) and make validation commands in `codex/RULES.md` runnable via SwiftPM.

## Context
- Depends on: none
- Blocking: future release tasks that require validated guard/QA/perf checks

## Specification
- Create/update codex docs:
  - `codex/SCOPE.md` with the release-confidence goal and success criteria.
  - `codex/CODEMAP.md` with a current repo map.
- Add SwiftPM support:
  - Create `Package.swift` (macOS 14, library target for `Caloura`).
  - Exclude `Caloura/App/CalouraApp.swift` from the SwiftPM target.
  - Update `.gitignore` to ignore `.swiftpm/` but keep `.swiftpm/Package.resolved`.
- Validate:
  - Run `swift build`, `swiftlint`, `swift test`.
  - Run `xcodegen generate`.
  - Run `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug`.
  - Run guard-only release check:
    `RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6`.
- Document:
  - Update `codex/CONTEXT-CHAIN.md` with Task 00 summary.
  - Update `tasks/todo.md` checklist + evidence.

## Acceptance Criteria
- [ ] `codex/SCOPE.md`, `codex/CODEMAP.md`, and `codex/tasks/task-00.md` are complete.
- [ ] `Package.swift` exists and `swift build` succeeds.
- [ ] `swiftlint` succeeds (install via Homebrew if missing).
- [ ] `swift test` succeeds.
- [ ] `xcodegen generate` and `xcodebuild test` succeed.
- [ ] Release guard passes in guard-only mode.
- [ ] `codex/CONTEXT-CHAIN.md` updated and `tasks/todo.md` includes evidence.

## Notes
- Install SwiftLint if needed: `brew install swiftlint`.
- Keep scope limited to release-confidence + validation enablement.
