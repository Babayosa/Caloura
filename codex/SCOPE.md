# Project Scope

## Goal
Establish a repeatable release-confidence loop for Caloura (guardrails + QA + performance evidence) and ensure repo validation works via SwiftPM.

## Why
Release regressions around permissions, artifacts, and performance are costly; a fast, repeatable confidence loop reduces risk and shortens release cycles.

## What It Touches
- [ ] `.github/workflows/release-guard.yml` — enforce tag/version parity
- [ ] `scripts/release.sh` — guard-only checks and release packaging
- [ ] `scripts/public_download_qa.sh` — public download + onboarding/trial checks
- [ ] `scripts/permission_diagnose.sh` — mixed-build permission debugging
- [ ] `scripts/perf_audit.sh` — performance evidence collection
- [ ] `Caloura/App/PerformanceMetrics.swift` + `Caloura/App/CapturePipeline.swift` — capture timing instrumentation
- [ ] `Caloura/Capture/PermissionCoordinator.swift` — permission status guidance
- [ ] `Caloura/Models/AppState.swift` + `Caloura/Security/HistoryCrypto.swift` — history persistence audits
- [ ] `Package.swift` + `.gitignore` — SwiftPM validation support
- [ ] `codex/*` docs — scope + code map + task spec

## Architecture Notes
- Menu-bar SwiftUI app with `AppDelegate` wiring and NotificationCenter-driven actions.
- Capture pipeline orchestrates area/window/fullscreen capture, overlays, and post-capture actions.
- Permission flow is passive on launch and explicitly user-initiated for validation.
- History is encrypted at rest with a file-backed AES key + permission audits.

## Key Decisions
- Provide a SwiftPM library target (excluding `CalouraApp.swift`) so `swift build` / `swift test` are valid.
- Keep release confidence scripts as the primary guardrails for distribution.

## Out of Scope
- New capture features or UI redesigns
- Distribution channel changes (App Store, Homebrew, etc.)
- Large refactors unrelated to release confidence

## Success Criteria
- [ ] `swift build`, `swiftlint`, and `swift test` pass
- [ ] Release guard and public QA scripts run successfully
- [ ] `codex/CODEMAP.md` and `codex/tasks/task-00.md` are complete and accurate
