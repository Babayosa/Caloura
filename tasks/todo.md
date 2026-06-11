# Caloura — Audit Remediation (tasks/audit-2026-06-09-full.md)

**Started:** 2026-06-10 · **Contract:** /goal phases 0–5, evidence-first, one finding per branch/commit, main stays releasable.
**Key discovery:** runner image `macos-26` carries Xcode 26.4.1 (default) + 26.5, NOT 26.0 → workflows need runner label fix AND `xcode-version: "^26.0"` range together.
Prior plan archived → `tasks/archive/todo-2026-03-06-task09-release-plan.md`.

## Phase 0 — Safety net
- [x] 0.1 Fix CI runners: `macos-26` in ci.yml/release-smoke.yml/release-guard.yml + `xcode-version: ^26.0` (one change, single root cause)
- [x] 0.2 Brewfile replaces phantom `swiftlint@0.63.2` pins; rename misleading "with coverage" step
- [x] 0.3 coverage_gate.py wired into ci.yml via -resultBundlePath; artifact upload
- [x] 0.4 swiftlint --strict; add CalouraSystemTests/CalouraUITests to .swiftlint.yml included
- [x] 0.5 Gate-proof: 3 throwaway PRs (lint warning / deleted LicenseManager test / broken build) each observed RED; record run URLs; delete branches
- [x] 0.6 release-guard (smoke: parse fix merged PR #16, dispatch pending) + release-smoke green via workflow_dispatch

## Phase 1 — Branch-critical + quick wins
- [x] 1.1 sharingType == .none tests for PinnedScreenshotWindow + CountdownOverlay (observed red with excludeFromScreenSharing() commented out, then green)
- [x] 1.2 README/plan.md truth pass (macOS 26, Xcode 26, real CI description, v2.4.2); execute every documented command
- [x] 1.3 .gitignore += releases/; remove NSAccessibilityUsageDescription (project.yml); kSecAttrSynchronizable=false in KeychainHelper.writeData; drop which() fallback in validate_appcast_against_manifest.py find_sign_update

## Phase 2 — Correctness (failing test BEFORE each fix)
- [ ] 2.1 handleCaptureFailure resets isCapturing (CaptureExecutionService)
- [ ] 2.2 defer-based reset in captureDelayed countdown task (CaptureEntrypointService)
- [ ] 2.3 savePresets do/catch + log + status (PresetManager)
- [ ] 2.4 freezeCaptureTarget fallback instead of throw (ScreenCaptureManager+SCKCapture)
- [ ] 2.5 SHA-pin actions + concurrency groups (workflows stay green)

## Phase 3 — Performance (baseline FIRST, before/after numbers)
- [ ] 3.0 Baseline: perf_audit.sh + signpost evidence, capture w/ 50-item history
- [ ] 3.1 EmbeddingStore → actor; 4 call sites; termination flush bounded; new save/load ordering test
- [ ] 3.2 Single-pass .accurate OCR (OCREngine.recognizeTextWithBoundingBoxes); exactly one VNRecognizeTextRequest per enrichment
- [ ] 3.3 HistoryView.filteredScreenshots computed once per body
- [ ] 3.4 Re-measure: no main-thread file I/O during capture; perf_audit budgets pass

## Phase 4 — License URL (GATED: only if api.caloura.app DNS confirmed available; else report blocked-by-decision)
- [ ] 4.1 Vanity domain in project.yml; Debug build verifies live worker on both hostnames

## Phase 5 — Polish
- [ ] 5.1 Dedup: orderedPresentationScreens, HistoryWindowController metrics, deletingPathExtension, fileExtension(for:), crosshair geometry
- [ ] 5.2 codex/CODEMAP.md refresh (+ StatusMessageRouter seam); archive plan.md
- [ ] 5.3 Dead code: DetectedContext.windowTitle, HistoryCrypto eager fallback URL, vacuous ReleaseScriptTests assertion
- [ ] 5.4 Test hygiene: AsyncGate instead of 50ms sleep, addTeardownBlock temp cleanup, XCTSkip headless system tests, drop NSCache actor wrapper

## Review / Evidence
- 0.1 PR #5 merged (c75661b). First green CI since 2026-04-28: run 27320567683 (build-test pass 3m53s). Root cause verified in logs of run 25078035743: "Could not find Xcode version that satisfied version spec: '26.0'" on macos-14. macos-26 image ships Xcode 26.4.1/26.5 → ^26.0 range required.
- 0.2 PR #6 merged. Version assertion proven live: first run failed loudly (run 27321838249: "swiftlint 0.63.2 != pinned 0.63.3") → pin corrected to image-preinstalled 0.63.2 → green run 27321925569.
- 1.1 task-22 d22a89f. Red-proof: with excludeFromScreenSharing() commented out, testCountdownOverlayCreatesNonShareablePanel + testPinnedScreenshotWindowIsNonShareable fail (NSWindowSharingType 1 != 0); green restored, 6/6.
- 1.2 PR #7 merged. Executed: xcodegen generate ✓, xcodebuild build ✓, RELEASE_GUARD_ONLY=1 RELEASE_TAG=v2.4.2 ./scripts/release.sh 2.4.2 ✓ (guard checks pass).
- 1.3 PR #8 merged (4 atomic commits). KeychainHelperTests 9/9 green after sync-flag change.
- flake: testEnqueue_limitsConcurrentJobs asserted start ORDER of 2 concurrent jobs; failed PR #9 CI (run 27322059940, ["second","first"]) and 2 local pre-commit runs. Fixed in PR #11 (set-membership assertion), 5/5 green repeats.
- In flight: PR #9 (coverage gate, rerun after #11), PR #10 (strict lint + 41 fixes), PR #11 (flake fix).

## ⚠️ ACTION NEEDED (user)
Test runs (unsigned test host) fired AppMover and replaced /Applications/Caloura.app with an unsigned DEBUG build; your signed 2.5.0 is intact at ~/.Trash/Caloura.app. Sandbox denied my restore. Run:
  trash /Applications/Caloura.app && cp -Rp ~/.Trash/Caloura.app /Applications/
Root-cause fix (test host can never trigger AppMover) landed separately — see evidence log.

- 0.3 PR #9 merged. Gate live: first run caught a REAL gap (ScreenCaptureManager+Permission 70.11% < 85 headless) -> covered via DI seams to 91.38%, run 27324137758 green.
- 0.4 PR #10 merged: --strict + 41 violations fixed properly; size rules warning==old error (sanctioned hard-cap form; PermissionCoordinator split deferred per contract).
- 0.5 GATE-PROOFS (all red, recorded, branches deleted): lint run 27324885375 (identifier_name error, exit 2); coverage run 27324885783 (UpdateManager.swift 31.29% < 85); build run 27324630230 (emit-module fail). Note: first lint proof was invalid (comment line; ignores_comments:true) and LicenseManager kept >=90% via redundant suites — both proofs strengthened. PR #15/#13/#14 closed unmerged.
- 0.6 release-guard workflow_dispatch run 27324842720 SUCCESS (30s). release-smoke: was UNPARSEABLE since creation (runner.temp in job-level env -> 0s failures on every tag push) — fixed in PR #16 (merged), re-dispatched.
- Flake root cause #2 (the big one): FoundationModels LanguageModelSession EXC_BREAKPOINT inside unsigned XCTest hosts (crash report xctest-2026-06-11-011546.ips) — SmartMetadataGenerator now short-circuits in test hosts (PR #17). 3 consecutive full-suite runs green; previously ~50% crash rate.
- Test-host safety: PR #12 merged (TestEnvironment hard gate; AppMover can never fire in tests).
- Permissions rework S1 committed on audit/permissions-rework: PermissionStore (24 tests), 722 green, coordinator 875->802.

## Permissions rework S2 — publication gate (DONE, uncommitted on audit/permissions-rework)
- [x] Single publish(_ candidate:source:) path; route ALL permissionUIModel writes (updateUIModel via publishStatus, updateCooldownInModel, cooldown timer)
- [x] Gate: diagnosis preservation unchanged (INVARIANT-5); .passive deferred to deferredPassiveEvidence while inFlightValidation != nil; .serializedFlow always applies
- [x] Flow completion re-evaluates deferred slot with FRESH store context via PermissionStatusCore.passiveStatus, published through the same gate
- [x] Internal flow calls to refreshPassiveStatus rerouted as .serializedFlow (behavior-preserving)
- [x] New CalouraTests/CaptureTests/PermissionPublicationGateTests.swift (4 tests, INVARIANT-3/5 tagged)
- [x] swift build + swift test x2 + swiftlint --strict green; 13 existing permission test files UNMODIFIED

S2 evidence: swift build "Build complete! (7.44s)"; swift test x2 = 726 tests 0 failures both runs (722 existing + 4 new); swiftlint lint --quiet --strict exit 0; git diff --name-only CalouraTests/ = empty (no test files modified). Remaining raw permissionUIModel writes: line 67 declaration default, line 712 + updateUIModel (927) both inside publish() apply branch only.

## STOPPED 2026-06-11 ~01:50 — session usage limit (resets 2:50am NY)
Rework branch audit/permissions-rework pushed (design doc + S2 commit ebb0a29; S1 rode into main via PR #17 — see PR comment).
S3 (RecoveryPlanner) NOT started in code: interrupted agent only read files; tree clean, builds green.
NEXT: (1) dispatch S3 per tasks/permissions-rework-design.md stage spec; (2) S4 facade slim; (3) open rework PR; (4) check release-smoke dispatch result (gh run list --workflow=release-smoke.yml); (5) remaining plan phases 2.x/3.x/5.x; Phase 4 license URL still blocked on DNS decision.
REMINDER (user): put the signed app back — trash /Applications/Caloura.app && cp -Rp ~/.Trash/Caloura.app /Applications/
