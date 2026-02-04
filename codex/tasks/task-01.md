# Task 01: CI Checks

## Objective
Add CI that enforces the release-confidence validation loop on every PR and main push.

## Context
- Depends on: task-00
- Blocking: reliable release confidence on PRs

## Specification
- Add `.github/workflows/ci.yml` that runs on `pull_request` and `push` to `main`.
- Install required tools (SwiftLint + XcodeGen) in CI.
- Run validations in order:
  1. `swift build`
  2. `swiftlint`
  3. `swift test`
- Run Xcode parity checks:
  - `xcodegen generate`
  - `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -destination 'platform=macOS'`
  - Disable code signing in CI (`CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=""`).
- Update `codex/CODEMAP.md` to mention the CI workflow.
- Update `codex/CONTEXT-CHAIN.md` and `tasks/todo.md` with evidence.

## Acceptance Criteria
- [ ] `.github/workflows/ci.yml` exists and runs SwiftPM + Xcode validations.
- [ ] `codex/CODEMAP.md` updated to reference CI checks.
- [ ] `swift build`, `swiftlint`, `swift test` pass locally.
- [ ] `xcodegen generate` and `xcodebuild test` pass locally.
- [ ] `codex/CONTEXT-CHAIN.md` and `tasks/todo.md` updated with Task 01 results.

## Notes
- CI should avoid code signing requirements by setting explicit flags.
