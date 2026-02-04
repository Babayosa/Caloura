# Task 02 — Public Download QA Script

Date: 2026-02-04  
Owner: Caloura Engineering  
Status: Complete

## Plan Checklist

- [x] Create `codex/tasks/task-02.md`
- [x] Update `scripts/public_download_qa.sh` for current v1.0.6 behavior (file-backed history, no runtime keychain)
- [x] Update runbook/docs if needed (`tasks/public-download-qa-runbook.md`, `README.md`)
- [x] Run required validation: `swift build`, `swiftlint`, `swift test`
- [x] Smoke the script locally (`manual-checks`, usage/errors)
- [x] Update `codex/CONTEXT-CHAIN.md` and commit

## Review / Evidence

- `swift build` (succeeded)
- `swiftlint` (succeeded; warnings only — 18 violations, 0 serious)
- `swift test` (99 tests passed)
- `scripts/public_download_qa.sh manual-checks` (prints file-backed history expectations + perms)
- `scripts/public_download_qa.sh verify` (exits 1; requires explicit `--version`)
- `scripts/public_download_qa.sh --version 1.0.6 verify` (artifact HEAD returns HTTP 200)
- `scripts/public_download_qa.sh --version 1.0.6 clean-room-reset` (succeeded; storage snapshot shows history state removed)

---

# Task 01 — CI Checks

Date: 2026-02-04  
Owner: Caloura Engineering  
Status: Complete

## Plan Checklist

- [x] Create `codex/tasks/task-01.md`
- [x] Add CI workflow (`.github/workflows/ci.yml`) for SwiftPM + Xcode checks
- [x] Update `codex/CODEMAP.md` for CI
- [x] Run required validation: `swift build`, `swiftlint`, `swift test`
- [x] Run Xcode parity checks: `xcodegen generate`, `xcodebuild test` (+ no-sign variant)
- [x] Update `codex/CONTEXT-CHAIN.md` and commit

## Review / Evidence

- `swift build` (succeeded)
- `swiftlint` (succeeded; warnings only)
- `swift test` (99 tests passed)
- `xcodegen generate` (succeeded)
- `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug` (99 tests passed)
- `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` (99 tests passed)

---

# Task 00 — Release Confidence Loop

Date: 2026-02-04  
Owner: Caloura Engineering  
Status: Complete

## Plan Checklist

- [x] Create/update `codex/` docs (`SCOPE.md`, `CODEMAP.md`, `codex/tasks/task-00.md`)
- [x] Add SwiftPM support (`Package.swift`, `.gitignore` updates)
- [x] Run required validation: `swift build`, `swiftlint`, `swift test`
- [x] Run release-confidence checks: `xcodegen generate`, `xcodebuild test`, release guard
- [x] Update `codex/CONTEXT-CHAIN.md` and commit

## Review / Evidence

- `brew install swiftlint` (installed SwiftLint 0.63.2)
- `swift build` (succeeded; CGWindowListCreateImage deprecation warnings)
- `swiftlint` (succeeded; 0 serious, warnings only)
- `swift test` (99 tests passed)
- `xcodegen generate` (succeeded)
- `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug` (99 tests passed)
- `RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6` (guard-only checks passed)

---

# Documentation Maintenance Checklist

Date: 2026-02-04
Owner: Caloura Engineering
Status: Complete

## Documentation Freshness Cadence

- [x] Weekly README accuracy review policy documented.
- [x] Per-release version/reference review policy documented.
- [x] Per-UX-change runbook update policy documented.

## Release Documentation Checklist

- [x] `README.md` updated for current onboarding/permission/auth/runtime behavior.
- [x] `README.md` release guard and public QA pointers verified.
- [x] `tasks/public-download-qa-runbook.md` normalized for v1.0.6 checks.
- [x] `tasks/security-performance-audit.md` refreshed with onboarding UX and release evidence checks.
- [x] `plan.md` rewritten as a concise current-state plan.
- [x] Legacy snapshots archived under `tasks/archive/`.

## Runbook Validation Checklist

- [x] `scripts/public_download_qa.sh` usage output validated.
- [x] `scripts/permission_diagnose.sh` exists and is executable.
- [x] `RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6` passed.
- [x] Primary docs checked for stale `1.0.5` references where `1.0.6` is expected.
- [x] Primary docs checked for stale 4-step onboarding references.
- [x] Primary docs checked for conflicting runtime keychain claims.

## Docs Audit Summary

- Command: `scripts/public_download_qa.sh`
  Outcome: prints usage successfully (no command errors).
- Command: `test -x scripts/permission_diagnose.sh`
  Outcome: passed (`scripts/permission_diagnose.sh` is executable).
- Command: `RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6`
  Outcome: passed (`Release tag check passed`, `Guard-only mode passed`).
- Content drift checks on primary docs (`README.md`, `plan.md`, `tasks/public-download-qa-runbook.md`, `tasks/security-performance-audit.md`):
  - `1.0.5` stale references: none found
  - 4-step onboarding references: none found
  - runtime keychain claims: consistent with no-startup-prompt model
- Manual doc QA:
  - no placeholder TODOs in active user-facing docs
  - referenced local doc/script paths resolve
  - duplicate checklist line removed from public QA runbook
