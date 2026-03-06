# Context Chain

Running log of completed tasks. Read this to understand what changed before your current task.

---

## Task 09: Release hardening continuation
**Status:** In Progress  
**Branch:** codex/task-09-release-hardening-continuation  
**Changes:**
- Eliminated the remaining Xcode test warning bar by refactoring XCTest lifecycle isolation in UI, capture-manager, URL-scheme, and signed-license backend tests
- Confirmed a clean warning-free `xcodebuild test` log and kept `swift build`, `swiftlint lint --quiet`, `swift test`, `xcodegen generate`, `xcodebuild build`, and `xcodebuild test` green
- Pushed the canonical `scripts/release_ready.sh --guard-only` flow through local validation, coverage, UI automation preflight, and dedicated UI smoke tests until it stopped at the expected Release entitlement-config guard
- Removed the remaining repo-local `unsafeBitCast` sites in AX / Security CF bridge wrappers after runtime type-ID checks
- Fixed a real manual scroll-capture race where `Finish` could finalize before the last settled viewport was accepted, which had surfaced as an Xcode-only flaky synthetic test

**Decisions Made:**
- Treat warning-free Xcode build/test logs as a hard local release invariant, not just a cleanup goal
- Keep moving the repo forward past the local gate even when the next blockers are external release-environment inputs (Release entitlement config, notary profile, live appcast parity)
- Treat Xcode-only synthetic test flakes as product bugs until proven otherwise; the manual scroll finish race was fixed in the engine instead of weakening the assertion

---

## Task 08: Release Readiness Hardening + Re-Audit
**Status:** Complete  
**Branch:** codex/task-08-release-readiness  
**Changes:**
- Cleared the remaining app-scheme Xcode warning bar and kept `swift build`, `swift test`, `xcodegen generate`, `xcodebuild build`, and `xcodebuild test` green
- Added `CalouraSystemTests` plus system-level checks for area/fullscreen entry cues, window picker visibility, compact quick-access width, and permission-repair onboarding entry
- Added `scripts/release_ready.sh` as a single release-preflight entrypoint and updated `scripts/release.sh` to archive against an explicit macOS destination
- Hardened release-critical correctness paths: ordered history persistence revisions, collision-safe artifact naming, clamped future trial dates with scheduled license revalidation, transient-safe embedding-store loads, explicit window picker startup failure handling, and app category metadata
- Collected fresh release evidence: warning-free Xcode logs, strict perf-gate output, live Sparkle appcast mismatch confirmation, and a full release-script run that now fails only at missing notary credentials on this machine

**Decisions Made:**
- Treat zero app-scheme build/test warnings as a hard local gate, while leaving broader SwiftLint style debt as tracked technical debt
- Make `release_ready.sh` default to the full packaging/notarization path, with an explicit `--guard-only` escape hatch for local guard runs
- Fix in-repo release blockers immediately and leave external release-ops issues (live appcast parity and notary credentials) as explicit ship blockers in the re-audit

---

## Task 07: Capture UX + Engine Hardening
**Status:** Complete  
**Branch:** codex/task-07-capture-hardening  
**Changes:**
- Added session coordinators and a shared cursor controller so area/fullscreen capture presents immediately with explicit mode cues and crosshair ownership independent of frozen screenshot readiness
- Added `CapturePerformanceRecorder` instrumentation for app activation, overlay/picker visibility, screenshot duration, raw preview visibility, save completion, and clipboard completion
- Moved area/fullscreen primary SCK capture to display-space rect capture and restricted `SCShareableContent` caching/prewarm to window workflows
- Reordered the main capture pipeline so the raw preview chip appears before deferred OCR/PII/history enrichment completes
- Replaced the long fixed quick-access toolbar with a compact contextual `4 + More` chip backed by a shared presentation model and centralized quick-action routing
- Added validation coverage for quick-access presentation, capture performance summaries, rect conversion, and preview phase transitions
- Ran validations (`swift build`, `swiftlint lint --quiet`, `swift test`, `xcodegen generate`, `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`)

**Decisions Made:**
- Prioritize immediate mode feedback over frozen-background perfection by backfilling snapshot imagery after the overlay is already visible
- Use rect-based ScreenCaptureKit capture as the default for area/fullscreen to remove unnecessary shareable-content latency from the hot path
- Treat post-capture preview as the primary UX milestone and defer enrichment rather than blocking the quick-access UI

---

## Task 06: Scroll Capture Engine V2
**Status:** Complete  
**Branch:** codex/task-06-scroll-capture-v2  
**Changes:**
- Rebuilt scroll capture around a viewport-aware `ScrollCaptureEngine` with adaptive automatic capture, direction calibration, absolute frame placement, seam-aware stitching, and guided manual fallback
- Added `ScrollCaptureSessionCoordinator` and upgraded the scroll progress overlay to show phase/mode and expose manual switch / finish controls
- Simplified exposed scroll preferences to `scrollToTop` and `maxHeight`; automatic viewport detection and sticky-header handling are now internal behavior
- Replaced helper-only coverage with synthetic end-to-end scroll engine tests for bottom reach, seam handling, sticky headers, manual fallback, cancellation, no-scroll targets, and max-height termination
- Ran validations (`swift build`, `swiftlint lint --quiet`, `swift test`, `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`)

**Decisions Made:**
- Prefer controlled manual fallback over attempting automatic capture on low-confidence or unstable scroll targets
- Use absolute placement plus seam selection instead of overlap clipping heuristics to avoid horizontal separator artifacts
- Keep the user-facing entrypoint unchanged while moving richer scroll state into internal engine/session types

---

## Task 05: Release 1.0.7 (public update)
**Status:** Complete (appcast live; Gumroad upload pending)  
**Branch:** codex/task-05-release-1-0-7  
**Changes:**
- Updated release references to 1.0.7 in `README.md`, `plan.md`, and QA runbooks
- Ran validations (`swift build`, `swiftlint`, `swift test`)
- Ran full release flow (`RELEASE_TAG=v1.0.7 ./scripts/release.sh 1.0.7`) and produced notarized zip
- Updated caloura-site appcast + download link and verified public artifacts

**Decisions Made:**
- Appcast and website publish completed; Gumroad upload still manual

---

## Task 04: Codex scope + codemap refresh
**Status:** Complete  
**Branch:** codex/task-04-codex-doc-refresh  
**Changes:**
- Refreshed `codex/CODEMAP.md` with updated runtime areas and runbook pointers
- Refreshed `codex/SCOPE.md` with foundation status and next-milestone scope
- Added `codex/tasks/task-04.md` and updated `tasks/todo.md`
- Removed safe ignored junk (`.DS_Store`, `.build/`, `DerivedData/`, `xcuserdata/`)

**Decisions Made:**
- Keep release-confidence as the foundation goal; add an explicit next-milestone section
- Cleanup limited to safe ignored junk; keep `build/`, `certs/`, `.codex/`, and archived task history

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
