# Task 08: Release Readiness Hardening + Re-Audit

## Objective
Drive the app scheme to a clean warning bar, add release/system-test gates, harden remaining release-critical paths, and rerun a production-readiness audit with current evidence.

## Context
- Depends on: task-07
- Blocking: none

## Specification
- Eliminate the remaining app-target Swift/Xcode warning-bar issues called out after Task 07, including the URL-scheme cleanup path, window picker callbacks, update delegate wiring, and scroll/sendability edges that blocked a clean Xcode build/test pass.
- Add a minimal macOS system-test target covering immediate area/fullscreen entry cues, window picker presentation, compact quick-access layout, and permission-repair entry UX.
- Add a single release-readiness script that runs the local validation stack, Xcode build/test, release checks, live appcast parity validation, and optional strict performance gates.
- Harden remaining release-critical correctness issues discovered during the re-audit:
  - ordered history persistence so stale snapshots cannot win
  - collision-safe artifact saving for smart names
  - clamped trial-day math and scheduled license revalidation
  - explicit window picker startup failure handling
  - app category metadata for release archives
- Re-run the validation stack and collect fresh release/performance/audit evidence.

## Acceptance Criteria
- [x] `swift build`, `swiftlint lint --quiet`, `swift test`, `xcodegen generate`, `xcodebuild build`, and `xcodebuild test` pass on the current branch.
- [x] App-scheme Xcode build/test logs are warning-free.
- [x] A minimal `CalouraSystemTests` target exists and runs in the app scheme.
- [x] `scripts/release_ready.sh` exists and exercises release checks; `scripts/release.sh` archives without the prior destination warning.
- [x] Release-critical in-repo fixes landed for history ordering, smart filename collisions, trial clamping/revalidation scheduling, and window picker startup failure handling.
- [x] A fresh production-readiness re-audit is produced with exact citations and a release decision.

## Notes
- External release blockers still remain outside the repo code path on this machine: the live Sparkle appcast still advertises macOS 14.0 while the app requires 26.0, strict perf gates are still missing several preview metrics, and notarization cannot complete until the `Caloura-Notarize` keychain profile is provisioned.
