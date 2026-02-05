# Task 03: Performance Evidence Loop Hardening

## Objective
Make performance evidence collection reliable and repeatable by ensuring metric samples are discoverable and the audit script captures clear metadata.

## Context
- Depends on: task-02
- Blocking: repeatable release performance evidence for candidate builds

## Specification
- Update performance metric logging so `metric_sample` events are emitted at info level:
  - `Caloura/App/CapturePipeline.swift`
  - `Caloura/UI/HistoryView.swift`
- Harden `scripts/perf_audit.sh`:
  - Preflight `python3` availability with an actionable error if missing.
  - Include `--info` in `log show` to capture info-level metric samples.
  - Improve the "no logs found" guidance to instruct generating captures + history opens.
  - Add environment metadata to the Markdown summary (macOS version/build, hardware model, CPU, minutes window, optional app version if `/Applications/Caloura.app` exists).
- Add a contract test to lock key stage names used by the audit script:
  - `CalouraTests/AppTests/PerformanceMetricsTests.swift`
- Update documentation evidence:
  - `tasks/security-performance-audit.md` guidance if it lacks capture/history generation steps.
  - Record Task 03 checklist + evidence in `tasks/todo.md`.
  - Summarize changes in `codex/CONTEXT-CHAIN.md`.

## Acceptance Criteria
- [ ] `metric_sample` logs are emitted at info level for capture and history open stages.
- [ ] `scripts/perf_audit.sh` uses `log show --info` and fails fast when `python3` is missing.
- [ ] Markdown audit output includes OS/hardware metadata and the minutes window.
- [ ] Stage-name contract test exists and passes.
- [ ] `swift build`, `swiftlint`, `swift test` pass.
- [ ] `tasks/todo.md` and `codex/CONTEXT-CHAIN.md` updated with Task 03 evidence.

## Notes
- Keep scope limited to performance evidence reliability. No capture behavior changes.
