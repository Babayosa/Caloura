# Context Chain

Running log of completed tasks. Read this to understand what changed before your current task.

---

## Task 03: Performance evidence loop hardening
**Status:** Complete  
**Branch:** task-03-performance-evidence  
**Changes:**
- Emit `metric_sample` logs at info level for capture + history metrics
- Hardened `scripts/perf_audit.sh` (python3 preflight, `--info` log capture, metadata in summaries, clearer no-log guidance)
- Added stage-name contract test for perf audit expectations
- Updated `tasks/security-performance-audit.md` and added `codex/tasks/task-03.md`

**Decisions Made:**
- Keep `python3` for perf summary generation; fail fast with an explicit install hint
- Use info-level metric samples to ensure `log show --info` can retrieve evidence

---

## Task 02: Public download QA script updates
**Status:** Complete  
**Branch:** task-02-public-download-qa  
**Changes:**
- Updated `scripts/public_download_qa.sh` to match v1.0.6 runtime behavior (file-backed encrypted history, no runtime keychain dependency)
- Removed the hard-coded default version and now require explicit `--version` for artifact/QA commands
- Clean-room reset now clears file-backed history state and prints storage snapshots (existence + permissions)
- Added `KEEP_QUARANTINE=1` option to keep quarantine attributes for Gatekeeper validation
- Updated runbook (`tasks/public-download-qa-runbook.md`) and `tasks/todo.md` evidence

**Decisions Made:**
- Treat keychain deletions as legacy best-effort cleanup only; history must not depend on keychain at runtime
- Prefer requiring explicit `--version` over relying on stale defaults

---

## Task 01: CI checks
**Status:** Complete  
**Branch:** task-01-ci-checks  
**Changes:**
- Added `.github/workflows/ci.yml` to run SwiftPM + Xcode checks on PRs and main pushes
- Added Task 01 spec (`codex/tasks/task-01.md`) and updated `codex/CODEMAP.md`
- Updated `tasks/todo.md` with Task 01 checklist + evidence

**Decisions Made:**
- Run `swift build`, `swiftlint`, `swift test` plus `xcodegen generate` and `xcodebuild test` in CI
- Disable code signing in CI to avoid certificate requirements

---

## Task 00: Release confidence loop + SwiftPM validation
**Status:** Complete  
**Branch:** task-00-release-confidence-loop  
**Changes:**
- Added SwiftPM support (`Package.swift`, `.gitignore` updates) to enable `swift build` / `swift test`
- Added SwiftLint configuration (`.swiftlint.yml`) to scope linting to repo sources
- Added codex docs (`codex/SCOPE.md`, `codex/CODEMAP.md`, `codex/tasks/task-00.md`)
- Updated `tasks/todo.md` with Task 00 checklist + evidence
- Consolidated existing release-confidence changes (CI guard + scripts + permission/perf updates)

**Decisions Made:**
- Use a SwiftPM library target excluding `Caloura/App/CalouraApp.swift` to avoid duplicate `@main`
- Disable several SwiftLint rules to avoid failing on legacy code until cleanup work

---

<!-- Add new task entries above this line -->
