# Project Scope

## Goal (Foundation)
Maintain a repeatable release-confidence loop for Caloura (guardrails + QA + performance evidence) and keep repo validation working via SwiftPM.

## Status
- Foundation work completed via Tasks 00–03 on 2026-02-04.
- Task 04 (2026-02-05) refreshes scope/code map docs and performs safe housekeeping.

## Why
Release regressions around permissions, artifacts, and performance are costly; a fast, repeatable confidence loop reduces risk and shortens release cycles.

## What It Touches
- [x] `.github/workflows/release-guard.yml` — enforce tag/version parity
- [x] `.github/workflows/ci.yml` — PR/push validation (SwiftPM + Xcode)
- [x] `scripts/release.sh` — guard-only checks and release packaging
- [x] `scripts/public_download_qa.sh` — public download + onboarding/trial checks
- [x] `scripts/permission_diagnose.sh` — mixed-build permission debugging
- [x] `scripts/perf_audit.sh` — performance evidence collection
- [x] `Caloura/App/PerformanceMetrics.swift` + `Caloura/App/CapturePipeline.swift` — capture timing instrumentation
- [x] `Caloura/Capture/PermissionCoordinator.swift` — permission status guidance
- [x] `Caloura/Models/AppState.swift` + `Caloura/Security/HistoryCrypto.swift` — history persistence audits
- [x] `Package.swift` + `.gitignore` — SwiftPM validation support
- [x] `codex/*` docs — scope + code map + task specs
- [x] `tasks/*` runbooks — public QA + performance audit guidance

## Architecture Notes
- Menu-bar SwiftUI app with `AppDelegate` wiring and NotificationCenter-driven actions.
- Capture pipeline orchestrates area/window/fullscreen capture, overlays, and post-capture actions.
- Permission flow is passive on launch and explicitly user-initiated for validation.
- History is encrypted at rest with a file-backed AES key + permission audits.

## Key Decisions
- Provide a SwiftPM library target (excluding `CalouraApp.swift`) so `swift build` / `swift test` are valid.
- Keep release confidence scripts as the primary guardrails for distribution.

## Next Milestone (Post-Foundation)
- Permission UX final polish (validate mixed-build scenarios; tighten copy only if real-user testing surfaces confusion).
- Security hardening roadmap (evaluate stronger local license-state protection without reintroducing onboarding friction).
- Performance evidence cadence (keep KPI tracking + perf audits per release candidate).

## Out of Scope
- New capture features or UI redesigns
- Distribution channel changes (App Store, Homebrew, etc.)
- Large refactors unrelated to release confidence

## Success Criteria
- [ ] `swift build`, `swiftlint`, and `swift test` pass
- [ ] CI and release guard enforce the loop
- [ ] Public QA + performance audit tools are runnable and documented
- [ ] `codex/CODEMAP.md` and `codex/SCOPE.md` reflect the current repo state
