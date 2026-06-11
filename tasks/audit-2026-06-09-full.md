# Audit: Caloura @ task-22-window-sharing-stealth — 2026-06-09 (full four-phase)

Stack: Swift 6 / macOS 26 menu-bar app (XcodeGen + SwiftPM dual build, SwiftLint, GitHub Actions, Sparkle direct-download distribution)
Dimensions: architecture/docs · security · correctness · performance/concurrency · dead-code/DRY · build/CI/deps · tests
Coverage: full (35k LOC; 6 parallel read-only auditors + orchestrator verification pass)
Saved by: codebase-audit skill. Prior same-day scoped audit: `audit-2026-06-09.md` (+ closure). This file is the full-repo pass.

---

## Executive Summary

**Health grade: B.** The code itself is unusually healthy for an indie macOS app — Swift 6 strict concurrency, zero force-unwraps in production, 77% test-to-prod LOC ratio, a documented sandbox decision, and a defense-in-depth release pipeline. The grade is dragged down by one operational failure and documentation rot: **CI has been red on every push since ~April 28** (verified via run logs: `Could not find Xcode version that satisfied version spec: '26.0'` on the `macos-14` runner), which means every quality gate the project nominally has (build, lint, tests) has been silently inert for ~6 weeks. Top 3 risks: (1) dead CI = no automated safety net while actively shipping releases; (2) the coverage gate exists but never runs in CI, so its thresholds are a false safety net even when CI is green; (3) the current branch's headline feature (window-sharing stealth) has its privacy guarantee untested on 2 of the windows that rely on it. Top 3 opportunities: fix the runner label (one line, restores the whole gate stack), wire `coverage_gate.py` + `--strict` lint into CI, and a one-hour README/docs refresh that eliminates every doc finding.

---

## Repo Map

**Purpose.** Caloura is a macOS menu-bar screenshot utility (area/window/fullscreen capture via ScreenCaptureKit) with on-device OCR + PII detection/redaction, smart crop, annotation, "Beautify" themes, AES-GCM-encrypted searchable history, and Sparkle in-app updates. Distributed as a direct-download DMG from caloura.app (no App Store), deliberately un-sandboxed (`docs/SANDBOX-DECISION.md`). Licensed via a signed-entitlement Cloudflare Worker backend. Maturity: **active pre-release product**, v2.4.2 / build 20 (`project.yml:21-22`).

**Entry point & flow.** `CalouraApp.swift` (@main) → `AppDelegate` wires `StatusMessageRouter`, permission refresh, hotkeys, URL scheme. Capture flow: hotkey → `AppCommandController` → `CapturePipeline.shared` → `CaptureEntrypointService` → overlay/selection UI → `CaptureExecutionService` → `ScreenCaptureManager` (SCK) → `ImageProcessor` → clipboard/save → deferred `CaptureEnrichmentService` (OCR/PII/embeddings) → `QuickAccessOverlay`.

**Key directories.**
- `Caloura/App/` — lifecycle, command routing, capture orchestration services, license, updates (34 files; grew most in tasks 18–22)
- `Caloura/Capture/` — SCK capture, 7-state permission machine, overlay windows, cursor control
- `Caloura/Processing/` — image processing, OCR, PII, redaction, beautify
- `Caloura/Models/` — `@Observable` AppState/AppSettings, embedding store
- `Caloura/Security/` — AES-GCM history crypto, keychain helper
- `Caloura/Distribution/` — clipboard, file saving, export
- `Caloura/UI/`, `Caloura/Context/`, `Caloura/HotKeys/` — UI surfaces, preset/context detection, global hotkeys
- `scripts/` — release/publish/guard pipeline + validators; `codex/` — agent docs (CODEMAP stale); `tasks/` — runbooks/audits

**Conventions.** Closure-injection DI on `@MainActor @Observable` singletons (28 `static let shared`); structured `CaptureError` → `UserFacingErrorMessage`; `os.log`; `SWIFT_STRICT_CONCURRENCY: complete`. Recommendations below fit this culture (no DI-framework rewrite proposed).

**Surprises.** CI red since April unnoticed; README claims macOS 14/Xcode 15 while the app requires macOS 26/Xcode 26; the "SwiftPM tests with coverage" CI step (`ci.yml:37-38`) runs plain `swift test` with no coverage flag.

---

## Audit Report

### Critical

- **[critical][reachable] `.github/workflows/ci.yml:11` + `:19` (also `release-smoke.yml:16/58`) — CI dead on every push.** Runner `macos-14` cannot provide Xcode 26; **verified** in run logs (runs 25078035743, 25077567818 et al., all failures ≤16s since 2026-04-28). Build, lint, and tests have not executed on any push for ~6 weeks; release-smoke fails at 0s. *Fix: move to a Tahoe-capable runner label (e.g. `macos-26`/current equivalent) in all three workflows; pin `release-guard.yml:20` off floating `macos-latest` to the same label.*

### High

- **[high][reachable] `scripts/coverage_gate.py` not wired into CI (`ci.yml` has no invocation).** The 6 per-file thresholds (80–90%, incl. `LicenseManager.swift`) run only in local `release_ready.sh:178`. PRs can erase coverage of license/crypto code with a green check. *Fix: add `-resultBundlePath` to the xcodebuild test step and run `coverage_gate.py` on it; upload report artifact.*
- **[high][reachable] `ci.yml:28-29`, `release-smoke.yml:114-115` — version-pinned brew formulas don't exist.** `brew install swiftlint@0.63.2 xcodegen@2.42.0` always fails into the unpinned `|| brew install swiftlint xcodegen` fallback, so CI lints/generates with whatever is current — the pinning is decorative. *Fix: Brewfile with exact versions, or SHA-pinned release binaries.*
- **[high][reachable] `ci.yml:35` — `swiftlint lint --quiet` without `--strict`:** warnings never block PRs; lint debt accumulates invisibly. *Fix: add `--strict`; add `CalouraSystemTests`/`CalouraUITests` to `.swiftlint.yml:3-5` `included:`.*
- **[high][reachable] `README.md:65-66, 71-83` — README materially wrong:** claims macOS 14.0+/Xcode 15+ (app requires 26/26), claims `xcodebuild test` is "intentionally omitted from CI" (it runs, `ci.yml:42-54`), version examples pinned to v1.0.7 (actual 2.4.2; also `plan.md:1,49`). Any user or contributor following it fails. *Fix: one doc pass.*
- **[high][reachable] `Caloura/UI/PinnedScreenshotWindow.swift:87`, `CountdownOverlay.swift:68` — branch's privacy guarantee untested.** Both call `excludeFromScreenSharing()` but no test asserts `sharingType == .none` (WindowPrivacyTests covers only SingleWindowPresenter/QuickAccessOverlay; CaptureOverlayWindowTests covers the two overlay windows). A refactor can silently regress the stealth feature this branch exists for. *Fix: 2 assertions in `WindowPrivacyTests.swift`.*
- **[high][reachable] `Caloura/Models/AppState.swift:128,183,296`, `AppState+History.swift:55` — `EmbeddingStore.save()/load()` (JSON encode + AES-GCM + atomic disk write) runs on the main actor**, including from `pruneRecentScreenshotsIfNeeded` on the hot capture path → 20–80 ms main-thread stalls per capture when history is full. *Fix: make `EmbeddingStore` an actor or move I/O to `Task.detached(.utility)` (same fix covers `EmbeddingStore.swift:81-98` `@unchecked Sendable` concern).*
- **[high — accepted risk] `Caloura/Resources/Caloura.entitlements:6` — app-sandbox false.** Intentional and documented (`docs/SANDBOX-DECISION.md`); listed because it makes every other control the only defense layer. No action beyond keeping the decision doc current.

### Medium

- `project.yml:57` — license backend URL `caloura-license.bigdaddy1858.workers.dev` bakes your personal Cloudflare username into the app's trust model and every shipped binary. *Front it with `api.caloura.app`.* (Public key on `:58` is fine in source.)
- All 3 workflows — `actions/checkout@v4` / `maxim-lobanov/setup-xcode@v1` pinned by mutable tag, in workflows holding Developer ID p12 + notary secrets. *Pin to commit SHAs (Dependabot github-actions ecosystem already configured).*
- `Package.resolved` (v2) vs `Caloura.xcodeproj/.../Package.resolved` (v3) — same revisions today, no CI assertion they stay in sync. *Add a diff check.*
- `Caloura/Processing/OCREngine.swift:57-104` — double full-image Vision pass (`.fast` probe then `.accurate`) per PII-enabled enrichment; ~2× OCR cost on every capture. *Single `.accurate` pass; keep the no-text early exit.*
- `Caloura/UI/HistoryView.swift:63-159` — computed `filteredScreenshots` evaluated 3× per body pass (lowercasing all OCR text each time) on the main actor. *Compute once per body / cache via onChange.*
- `Caloura/App/CaptureExecutionService.swift:328-336` — `handleCaptureFailure` doesn't reset `isCapturing`; currently saved by the safety-net at `:116-118`, one refactor away from a stuck-true UI flag. *Reset inside the handler.*
- `Caloura/Capture/ScreenCaptureManager+SCKCapture.swift:109-114` — freeze-target resolution throws when Caloura isn't yet in `SCShareableContent.applications` (agent-app first capture after launch) → freeze backdrop silently absent. *Fall back to an unfiltered content filter instead of throwing.*
- `Caloura/Context/PresetManager.swift:141-145` — `savePresets()` swallows encode/write failure (`try?`, no log); user presets silently lost. *do/catch + log + status message.*
- `Caloura/Capture/ScreenCaptureManager+SCKCapture.swift:232,317-337` — `OneShotFrozenDisplayStreamCapture` holds `stateLock` across `SCStream` init/start; deadlock-shaped if SCK ever dispatches synchronously. *Narrow the critical section.*
- `Caloura/UI/MenuBarView.swift:11-18` — `GlobalShortcutsWatcher` discards its NotificationCenter token; re-inits accumulate phantom registrations. *Store token, remove in deinit.*
- `Caloura/Security/KeychainHelper.swift:60-91` — no explicit `kSecAttrSynchronizable: false` on the history root key write. *One-line hardening.*
- `Caloura/UI/QuickAccessOverlay.swift:110` — UI pierces `CapturePipeline.shared.distributionService` directly (boundary violation already flagged in `codex/LESSONS.md`). *Route via AppCommandRouter or inject.*
- `Caloura/Capture/PermissionCoordinator.swift` (875 lines) — known deferred god-object split; highest regression surface for permission changes.
- `codex/CODEMAP.md` — describes pre-task-18 architecture; missing all extracted services and the StatusMessageRouter seam; misleads any agent onboarding from it. *Refresh.*
- `Caloura/Capture/PermissionCooldownPolicy.swift` (50 LOC, date-injectable, alert/relaunch gating) and `Caloura/App/CaptureRequestResolver.swift:58` (preset routing) — zero direct test assertions. *Two small test files.*
- `CalouraTests/AppTests/URLSchemeHandlerTests.swift:14-43`, `LicenseManagerTests.swift:19` — tests mutate `AppState.shared`/`AppSettings.shared` with snapshot/restore; fragile under failure or parallel execution. *Construct isolated instances (DI already supports it).*
- Dup that already diverged: `Caloura/UI/HistoryView+WindowController.swift:9-50` re-implements `CaptureMetricsRecorder` logging minus the `metric_percentiles` line. Dup that will: `orderedPresentationScreens()` verbatim in `CaptureOverlayWindow.swift:126` + `ScreenSelectionOverlayWindow.swift:113`. *Delegate/consolidate.*
- `scripts/validate_appcast_against_manifest.py:38-41` — `sign_update` falls back to PATH lookup. *Drop the `which()` fallback.*
- `.gitignore` — `releases/` not ignored (4.2 MB DMG on disk one `git add .` from being committed). No `concurrency:` groups in any workflow.

### Low / nits

- `project.yml:77` — `NSAccessibilityUsageDescription` ships for removed Scroll Capture; remove until it returns.
- `ContextDetector.swift:66` — `DetectedContext.windowTitle` always nil, forwarded through `CaptureRequestResolver.swift:38`; dead field.
- `KeychainHelper.swift:115` `deleteItem` test-only; `HistoryCrypto.swift:212` eager dead fallback URL; `plan.md` stale (v1.0.7) — archive.
- `ci.yml:37` step named "SwiftPM tests with coverage" runs `swift test` with no coverage flag — misleading name.
- Tests: `CaptureEnrichmentServiceTests.swift:391` bare 50 ms sleep; temp files without `addTeardownBlock`; `CalouraSystemTests/CaptureSystemTests.swift:295` `XCTFail` instead of `XCTSkip` when headless; `ReleaseScriptTests.swift:97` asserts about a file that no longer exists (vacuous).
- `release.sh:55` team ID duplicated across 3 files; `release.sh:68` arm64-only undocumented; `release.sh:383-403` AppleScript DMG layout headless-fragile; `publish.sh:25` `$HOME/caloura-site` hardcoded default; `HistoryView.swift:4-48` NSCache wrapped in an actor (needless hop); `CalouraApp.swift:61` synchronous termination save with no timeout guard; `certs/` CSR committed (no private material — confirmed) — gitignore as hygiene.

### Refuted / corrected during red-team

- Cursor-rect reset duplication (prior audit A-8): **already fixed** — shared `resetCursorRects(for:)` at `CaptureSessionCoordinators.swift:272`.
- License enforcement, URL-scheme token defense, Sparkle EdDSA chain, path traversal, shell injection, NSKeyedUnarchiver, secrets-in-repo: **clean** (verified by security auditor; no private keys in `certs/`).
- The stealth feature itself is correctly scoped (`sharingType = .none` on Caloura-owned windows only); no TCC evasion or abuse surface.

### Strengths (preserve these)

1. Swift 6 strict concurrency, zero `try!`/`as!`/force-unwraps in production.
2. 77% test-to-prod LOC; behavioral tests with real assertions (ScreenshotArtifactCoordinator, history persistence migration/corruption cases, regression-labelled system tests).
3. Closure-injection DI at scale; `StatusMessageRouter` cleanly decouples Capture from AppState.
4. Release pipeline depth: version-parity guards at 3 checkpoints, EdDSA appcast validation + downgrade detection, ephemeral CI keychain hygiene, `flock`-guarded publish, pre-build Release-settings validator.
5. 7-state permission machine encoding hard-won TCC behavior, backed by 577 lines of tests.
6. Documented sandbox decision with threat model and re-evaluation triggers.

---

## Improvement Strategy

**Theme 1 — The safety net is disconnected from reality.** CI is red (runner/Xcode mismatch), the coverage gate never runs in CI, lint can't fail PRs, and brew pins silently fall back. *Target state: a green, trustworthy CI where a passing check actually means build+lint(strict)+tests+coverage passed.* Principle: a gate that can't fire is worse than no gate — it manufactures false confidence.

**Theme 2 — Documentation describes a project two major versions ago.** README (OS/Xcode/CI/version), plan.md, CODEMAP all contradict the code. *Target: docs a stranger (or agent) can follow without hitting a single false claim; CODEMAP reflects task-22 architecture.* Principle: in an agent-driven repo, stale docs are injected misinformation.

**Theme 3 — Hot-path main-actor work.** Embedding persistence, double OCR, repeated history filtering. *Target: zero synchronous disk/crypto/Vision work on the main actor during capture; one Vision pass per enrichment.* Principle: this is a latency product — the perf budgets in `perf_audit.sh` show the team already believes this.

**Theme 4 — Error paths trust a safety net instead of owning cleanup.** `handleCaptureFailure`, countdown cancellation, `savePresets` swallow. *Target: every state mutation has a same-scope reset (defer/handler-local), every swallowed error at least logs.*

**Explicitly NOT recommending:** dismantling the 28 singletons (documented decision, closure-DI makes them testable — continue incremental call-site cleanup only); adopting App Sandbox (documented trade-off, SCK constraints); certificate pinning on the license endpoint (Curve25519 signature verification is the correct defense, already in place); universal/Intel builds (macOS 26 minimum makes arm64-only correct — just document it); splitting PermissionCoordinator *this milestone* (high regression risk for zero user value; do it when permission work next opens that file).

**Definition of done:** CI green on a no-op push to main; CI fails when a lint warning, coverage drop below thresholds, or test failure is introduced (verify by deliberate red test); README contains zero false claims (spot-check each requirement/command); Instruments or perf_audit shows no main-thread file I/O during capture-with-full-history; the four Critical/High code findings each have a closing commit + test.

---

## Task Plan

### Quick wins (do immediately — all S, high impact)
| QW | Task | Files |
|---|---|---|
| QW1 | = M0.1 below: fix CI runner labels | 3 workflow files |
| QW2 | Add `sharingType == .none` tests for PinnedScreenshotWindow + CountdownOverlay | `WindowPrivacyTests.swift` |
| QW3 | README/plan.md truth pass (macOS 26, Xcode 26, real CI description, v2.4.2, xcodegen step, CI test cmd) | `README.md`, `plan.md` |
| QW4 | `.gitignore` += `releases/`; remove `NSAccessibilityUsageDescription` (`project.yml:77`); add `kSecAttrSynchronizable: false` (`KeychainHelper.swift`) | 3 files |
| QW5 | Drop `which()` fallback in `validate_appcast_against_manifest.py:38-41` | 1 file |

### Milestone 0 — Restore the safety net (everything else is unverifiable until this lands)
| # | Task | Acceptance | Effort | Risk | Deps |
|---|---|---|---|---|---|
| 0.1 | **Fix CI runners.** Replace `macos-14` (`ci.yml:11`, `release-smoke.yml:16`) and `macos-latest` (`release-guard.yml:20`) with one pinned Tahoe-capable label hosting Xcode 26. | All 3 workflows green on a push; setup-xcode resolves 26.0 | S | Low | — |
| 0.2 | **Real tool pinning.** Replace nonexistent `swiftlint@0.63.2` brew formulas with Brewfile or SHA-pinned binaries; rename/fix the "with coverage" step. | CI logs show the intended versions installed | S | Low | 0.1 |
| 0.3 | **Wire coverage gate into CI.** `-resultBundlePath` on xcodebuild test → `coverage_gate.py` step → artifact upload. | A PR deleting a LicenseManager test fails CI | M | Low | 0.1 |
| 0.4 | **Strict lint.** `--strict` in `ci.yml:35`; add system/UI test dirs to `.swiftlint.yml`; fix any surfaced warnings. | A warning-level violation fails CI | S–M | Low | 0.1 |
| 0.5 | Privacy regression tests (QW2). | Tests fail if `excludeFromScreenSharing()` removed | S | None | — |

### Milestone 1 — Critical correctness & security hardening
| # | Task | Acceptance | Effort | Risk | Deps |
|---|---|---|---|---|---|
| 1.1 | `handleCaptureFailure` resets `isCapturing` locally; demote safety-net to assertion; `defer`-based reset in `captureDelayed` countdown task (`CaptureEntrypointService.swift:218-247`) | Unit tests for each failure exit path | S | Low | 0.x |
| 1.2 | `savePresets()` do/catch + log + status message (`PresetManager.swift:141`) | Failing-encode test asserts log/status | S | Low | 0.x |
| 1.3 | Freeze fallback: don't throw on missing self in SCShareableContent (`+SCKCapture.swift:109-114`) | First-capture-after-launch shows frozen backdrop | S | Low–Med | 0.x |
| 1.4 | SHA-pin all GitHub Actions; add `concurrency:` groups to 3 workflows | Workflows reference full SHAs; duplicate runs cancel | S | Low | 0.1 |
| 1.5 | Front license worker with `api.caloura.app` custom domain; update `project.yml:57` | Shipped Info.plist shows vanity URL; worker still verifies | M | Med (touches license path — test against live worker before release) | — |
| 1.6 | Package.resolved sync assertion in CI (root v2 vs xcodeproj v3) | CI fails when the two lockfiles diverge | S | Low | 0.1 |

### Milestone 2 — High-leverage performance & tests
| # | Task | Acceptance | Effort | Risk | Deps |
|---|---|---|---|---|---|
| 2.1 | **EmbeddingStore off main actor** (actor conversion or detached I/O); fix all 4 call sites | No main-thread file I/O during capture w/ 50-item history (Instruments/os_signpost) | M | Med | 0.x |
| 2.2 | **Single-pass OCR** (`OCREngine.swift:57-104`) | PII enrichment runs one `VNRecognizeTextRequest`; existing OCR tests pass | M | Med | 0.x |
| 2.3 | HistoryView: compute `filteredScreenshots` once per body | One scan per render (measure) | S | Low | — |
| 2.4 | Tests: `PermissionCooldownPolicyTests` (clock-injected), `CaptureRequestResolverTests` | Both files' logic directly asserted | M | None | — |
| 2.5 | De-singleton test fixtures: URLSchemeHandler/LicenseManager tests use injected instances | No test touches `.shared` | M | Low | — |
| 2.6 | Narrow `stateLock` critical section in `OneShotFrozenDisplayStreamCapture` | Lock not held across SCStream init/start; freeze tests pass | S–M | Med | 2.4 era |

### Milestone 3 — Quality & polish
| # | Task | Effort |
|---|---|---|
| 3.1 | Dedupe: `orderedPresentationScreens()`, metrics logging in `HistoryView+WindowController`, `String.deletingPathExtension`, `fileExtension(for:)`, crosshair geometry | M |
| 3.2 | Refresh `codex/CODEMAP.md` (services map + StatusMessageRouter seam); archive `plan.md` | M |
| 3.3 | Dead code: `DetectedContext.windowTitle`, `HistoryCrypto` eager fallback, vacuous `ReleaseScriptTests:97` assertion | S |
| 3.4 | Test hygiene: replace 50 ms sleep with AsyncGate, `addTeardownBlock` temp cleanup, `XCTSkip` for headless system tests, drop NSCache actor wrapper | M |
| 3.5 | `GlobalShortcutsWatcher` token lifecycle; single-source team ID; document arm64-only + DMG-layout fallback; remove `tccutil` path if SIP-dead on 26+ | M |
| 3.6 | (When permission work next opens the file) split `PermissionCoordinator` per the deferred plan | L |

### Implementation sketches — top 3

**0.1 CI runners (the one-line fix that matters most).** Check `gh api /repos/{owner}/{repo}/actions` runner availability or runner-images README for the current Tahoe label (`macos-26` expected by mid-2026). Edit `runs-on:` in all three workflows to the same pinned label. Gotchas: `release-smoke.yml` failing at 0 s suggests a possible workflow-level parse/availability issue too — read its run's annotations after the runner fix; arm64 image assumed (release.sh already arm64-only); after green, immediately push a deliberately-broken commit to a branch to confirm the gate actually fails (per CLAUDE.md: never trust an untested gate).

**0.3 Coverage gate in CI.** Add `-resultBundlePath .build/ci.xcresult` to the xcodebuild test invocation; new step: `python3 scripts/coverage_gate.py --xcresult .build/ci.xcresult --output-dir .build/coverage` (match `release_ready.sh:178`'s exact flags); `actions/upload-artifact` the report. Gotchas: `coverage_gate.py` expects xccov-readable bundles — `CODE_SIGNING_ALLOWED=NO` doesn't affect coverage but `-skip-testing:CalouraUITests` means UI-only files must not be in the gate's threshold list (they aren't today); run time +~30 s.

**2.1 EmbeddingStore off main.** Convert `EmbeddingStore` to an `actor` (drop `@unchecked Sendable` + NSLock); make `save()`/`load()` `async`; call sites in `AppState` become `Task { await embeddingStore.save() }` — except `loadPersistedState`, where load order matters: keep an async load that publishes results back to the main actor when ready (history UI already tolerates deferred enrichment data). Gotchas: `applicationWillTerminate`'s synchronous flush (`CalouraApp.swift:61`) needs a bounded synchronous bridge (semaphore + 3 s timeout) or accept last-write-wins from the most recent async save; verify with the existing AppStateDeferredHistoryTests plus a new ordering test.

---

## Open Questions

1. **CI runner label:** confirm which GitHub-hosted image carries Xcode 26 on your plan (and whether release-smoke's 0-second failures share the runner root cause or are a separate workflow-availability issue).
2. **`api.caloura.app` for the license worker (1.5):** do you control DNS for caloura.app and want the cutover now, or defer to the next release window? Shipped builds embed the old URL — the worker must keep answering on both hostnames until old versions age out.
3. **Intel support:** arm64-only is implied by macOS 26 minimum — confirm so it can be documented as policy rather than accident.
4. **`plan.md` / `codex/CONTEXT-CHAIN.md`:** archive into `codex/`/`tasks/archive/`, or are they load-bearing for an active agent workflow?
5. **`tccutil reset` repair path (`ScreenCaptureManager+Permission.swift:87-104`):** has it ever succeeded on macOS 26 with SIP on? If permanently dead, removal simplifies PermissionCoordinator ahead of the deferred split.
