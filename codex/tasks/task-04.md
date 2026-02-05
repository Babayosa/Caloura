# Task 04: Codex Scope + Code Map Refresh

## Objective
Refresh the codex scope and code map to match the current repo state and remove safe ignored junk from the working tree.

## Context
- Depends on: task-03
- Blocking: none

## Specification
- Update documentation:
  - `codex/CODEMAP.md` with a current high-level map and verified pointers.
  - `codex/SCOPE.md` with a two-layer scope (release-confidence foundation + next milestone).
  - `codex/CONTEXT-CHAIN.md` with Task 04 summary.
  - `tasks/todo.md` with Task 04 checklist + evidence.
- Cleanup (delete if present; safe ignored junk only):
  - `.DS_Store`
  - `.build/`
  - `DerivedData/`
  - `Caloura.xcodeproj/xcuserdata/`
  - `Caloura.xcodeproj/project.xcworkspace/xcuserdata/`
- Do not delete:
  - `build/`
  - `certs/`
  - `.codex/`

## Acceptance Criteria
- [ ] `codex/CODEMAP.md` and `codex/SCOPE.md` reflect the current repo and next milestone.
- [ ] Safe ignored junk removed without touching `build/`, `certs/`, or `.codex/`.
- [ ] `codex/CONTEXT-CHAIN.md` and `tasks/todo.md` updated with Task 04 results.
- [ ] `swift build`, `swiftlint`, `swift test` pass.

## Notes
Keep scope limited to documentation refresh + safe cleanup only.
