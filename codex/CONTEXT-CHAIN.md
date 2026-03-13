# Context Chain

Running log of completed tasks. Read this to understand what changed before your current task.

---

## Task 15: Permission + capture production audit
**Status:** Complete  
**Branch:** `codex/task-15-permission-capture-audit`  
**Changes:**
- Audited the Screen Recording state machine and fixed a regression where `refreshPassiveStatus()` could erase an explicit `.needsRelaunch` or `.staleRecord` diagnosis and collapse the UI back to `.grantedNeedsValidation`
- Extracted a shared `onboardingFlowState(for:hasCompletedOnboarding:)` helper and reused it from both launch and permission-repair entrypoints so repair UI no longer shows `.completed` while Screen Recording still needs validation
- Removed duplicate AppKit activation from the window-capture entry path by leaving activation ownership inside `WindowCaptureSessionCoordinator`
- Added regression coverage for preserved permission diagnoses, shared onboarding mapping, and single-activation window picker presentation
- Revalidated with `swift build`, `swiftlint lint --quiet`, `swift test`, `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`, `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -only-testing:CalouraSystemTests/CaptureSystemTests`, `scripts/permission_diagnose.sh`, and `scripts/perf_audit.sh --strict --min-samples 5`

**Decisions Made:**
- Keep explicit permission-failure preservation in memory only, scoped to the current app identity, so a live failure stays actionable within the current run without turning passive startup mismatches into stale-record failures
- Centralize Screen Recording onboarding-state mapping in one helper rather than maintaining parallel switch statements in app launch and command routing
- Keep window activation at the picker coordinator boundary so the window-capture hot path has one activation owner and one timing source

---

## Task 16: Permission state core normalization
**Status:** Complete
**Branch:** `codex/task-16-permission-state-core`
**Changes:**
- Centralized Screen Recording passive-state resolution and terminal status publication inside `PermissionCoordinator` so passive refresh, interactive validation, settings-return revalidation, and capture-failure repair all share the same working / denied / explicit-failure side effects
- Added focused regression coverage proving that a fresh `requestPermissionFromSystem()` clears a previously diagnosed `.needsRelaunch` state and returns the coordinator to `.grantedNeedsValidation` until live validation succeeds again
- Tightened `CaptureEnrichmentCoordinatorTests` so the full suite no longer flakes on a fabricated start-order assumption when two enrichment jobs are allowed to begin concurrently
- Regenerated `Caloura.xcodeproj` so the new focused permission test is included in Xcode builds
- Revalidated with `xcodegen generate`, `swift build`, `swiftlint lint --quiet`, and `swift test` (489 tests passing)

**Decisions Made:**
- Funnel all Screen Recording status publication through shared helper paths rather than repeating diagnosis-clearing and working-state side effects at each call site
- Keep the normalization scoped to the permission coordinator; the only extra code change outside that area was the test-only fix required to make the full validation suite deterministic again
- For concurrent enrichment tests, assert the causal relationship that matters (slot opens before the queued job starts) instead of assuming scheduler order between jobs that may legitimately start in either order

---

## Task 17: Permission core split
**Status:** Complete
**Branch:** `codex/task-17-permission-core-split`
**Changes:**
- Extracted a pure `PermissionStatusCore` plus `PermissionStatusContext` so passive status resolution, explicit failure classification, permission UI model rendering, and non-blocking permission copy no longer live directly inside `PermissionCoordinator`
- Kept `PermissionCoordinator` as the owner of live validation, repair orchestration, persistence, cooldown state, and status publication side effects while delegating rule evaluation to the new core
- Added direct regression coverage for the extracted permission-rule engine and regenerated the Xcode project so the new source/test files are part of app-scheme builds
- Revalidated with `xcodegen generate`, `swift build`, `swiftlint lint --quiet`, `swift test`, and `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`

**Decisions Made:**
- Split only the pure rule engine out of the coordinator; keep repair, persistence, and orchestration behavior in the coordinator so this stays an internal refactor instead of a permission-architecture rewrite
- Test the extracted rule engine directly rather than only through coordinator integration paths, so future permission-copy or classification changes fail closer to the source of truth

---

## Task 14: Cursor-first capture hardening
**Status:** Complete  
**Branch:** `codex/task-14-cursor-hardening`  
**Changes:**
- Moved shared crosshair-session startup ahead of area/fullscreen overlay presentation so cursor ownership is established before any capture panel becomes visible
- Removed the cursor watchdog timer, kept reassertion on real window/view events, and added key-transition hooks on capture overlays to re-prime the crosshair when the active panel becomes key
- Replaced the cursor controller's `.set()`-based reassertion with balanced pop/push reinstallation, plus a coalesced next-turn re-prime and `didBecomeActive` coverage so AppKit's first cursor recomputation cannot easily reclaim the arrow
- Changed area/fullscreen overlay presenters to front the mouse-screen panel first and keep the remaining overlays non-key to reduce cursor churn on multi-display entry
- Added focused controller coverage for deferred cursor re-prime coalescing/cancellation, plus stronger coordinator and system assertions for real overlay reassertion and single-key-window behavior
- Revalidated with `swift build`, `swiftlint lint --quiet`, `swift test`, `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData`, and `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -only-testing:CalouraSystemTests/CaptureSystemTests`

**Decisions Made:**
- Keep the hardening on the shared session/overlay path so area and fullscreen stay behaviorally aligned
- Use an injected overlay-presenter seam in the coordinators for deterministic ordering tests instead of adding broader production abstractions
- Treat “first visible cursor frame” as the target and remove timer-based cursor polling in favor of explicit presentation, key-window ordering, and a single bounded deferred re-prime

---

## Audit Task 06: Access control tightening
**Status:** Complete  
**Branch:** `codex/task-06-access-control`  
**Changes:**
- Tightened `CapturePipeline.overlayWindows`, `screenOverlays`, `areaCaptureSession`, `fullscreenCaptureSession`, and `delayedCaptureTask` to `private(set)` in `Caloura/App/CapturePipeline.swift`
- Routed `CapturePipeline` state mutation through same-file helper methods so extension-based entry points and scroll capture logic can still update session state without exposing writable properties module-wide
- Tightened `ScreenCaptureManager.sckFailed` to `private(set)` and replaced direct test mutation with an explicit DEBUG test seam
- Tightened `URLSchemeHandler.lastHandledDate` to `private(set)` and replaced direct test mutation with `resetThrottleForTesting()`
- Restricted `captureAllScreens()` in `Caloura/App/CapturePipeline+FreezeCapture.swift` to `private`
- Revalidated with `swift build`, `swiftlint`, and `swift test` (465 tests passing)

**Decisions Made:**
- Use type-owned helper methods instead of broader setters for `CapturePipeline` because the mutable state is written from extension files and `private(set)` alone would have broken those writes
- Keep the new mutating seams narrow and task-scoped rather than refactoring unrelated mutable state like `captureSessionID` or `sckFailureCount`
- Preserve test coverage by replacing writable-global/property access with explicit DEBUG-only reset/set helpers where read-only production access was required

---

## Audit Task 05: Concurrency safety audit
**Status:** Complete  
**Branch:** `codex/task-05-concurrency`  
**Changes:**
- Audited every source-level concurrency escape hatch and documented the findings in `codex/tasks/audit-05-concurrency.md`, including current counts, per-site assessments, strict-concurrency probe evidence, and a Swift 6 migration roadmap
- Removed three `nonisolated(unsafe)` sites from `HistoryView` by replacing the thumbnail cache/metrics globals with an actor-backed `HistoryThumbnailStore`
- Fixed a real DEBUG-only synchronization bug in `HistoryCrypto` by routing override reads and writes through the same `keyQueue` that guards the cached key, then resolved the resulting SwiftPM test crash by making queue-backed helper access reentrant-safe
- Added locking to `DefaultScrollDriver` so its `@unchecked Sendable` conformance matches the `ScrollDriving: Sendable` contract
- Removed unnecessary unchecked sendability from `ScrollCaptureOutput` and `ScrollStitchResult` now that `CGImage` is Sendable on this toolchain
- Revalidated with `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`, `swift build`, `swiftlint`, and `swift test` (465 tests passing)

**Decisions Made:**
- Treat the reported `ScreenCaptureManager` and `CapturePipeline` race candidates as actor-isolated false positives after verifying all mutable state stays on `@MainActor`
- Keep `@preconcurrency` on ScreenCaptureKit, Sparkle, and the ScreenCaptureKit observer bridge because the macOS 26.2 SDK still lacks the needed Sendable annotations
- Leave the remaining `HistoryCrypto` globals on `nonisolated(unsafe)` for now, but only after tightening all access through the external queue and documenting them as Swift 6 blockers
- Keep the `HistoryCrypto` external-queue design for this task, but make nested helper reads reentrant-safe instead of broadening the refactor into an actor migration

---

## Audit Task 04: Error handling hardening
**Status:** Complete  
**Branch:** `codex/task-04-error-handling`  
**Changes:**
- Added structured `CaptureError` cases for invalid regions, timeouts, and no-content failures, and moved known ScreenCaptureKit / CLI empty-image paths onto those cases instead of generic string failures
- Updated `CapturePipeline` to turn capture failures into actionable status messages while preserving technical detail in logs, including a timeout mapping for non-`CaptureError` timeout failures
- Mapped `ScrollCaptureError` outcomes to user-friendly scroll-specific recovery messages and aligned the scroll progress overlay with the same failure wording
- Documented the SCK permission-denial boundary in `shouldTreatCaptureErrorAsPermissionDenied`, including the `SCStreamError.userDeclined` (`-3801`) classification
- Added focused regression coverage for structured capture errors, timeout messaging, and SCK user-declined permission classification; revalidated with `swift build`, `swiftlint`, and `swift test` (465 tests passing)

**Decisions Made:**
- Keep technical failure context in `logMessage` and reserve `errorDescription` / status text for recovery-oriented guidance
- Introduce timeout handling at the pipeline boundary instead of adding new capture-operation deadlines in this task
- Limit structured-case replacement to well-known invalid-region and empty-image paths, leaving truly unknown capture failures on the generic fallback path

---

## Audit Task 03: Singleton dependency audit
**Status:** Complete  
**Branch:** `codex/task-03-singletons`  
**Changes:**
- Audited all 25 custom `.shared` singletons and wrote the findings to `codex/tasks/audit-03-singletons.md`
- Counted distinct access-file fanout for each singleton across app and test code, then classified every item into Tier 1 / Tier 2 / Tier 3
- Cross-referenced the singleton catalog with the known test pollution issues around `AppSettings.shared.activePreset`, `AppState.shared.statusMessage`, and the singleton-adjacent `URLSchemeHandler.lastHandledDate`
- Added concrete DI blueprints for the Tier 1 set: `AppSettings`, `AppState`, `AppCommandRouter`, `PermissionCoordinator`, `CapturePipeline`, and `ScreenshotArtifactCoordinator`
- Revalidated with `swift build`, `swiftlint`, and `swift test` (460 tests passing)

**Decisions Made:**
- Treat the singleton problem as concentrated debt in a small set of mutable root services, not a flat “all 25 are equally urgent” cleanup
- Use access-file fanout plus existing test pollution as the threshold for Tier 1, rather than raw singleton count alone
- Prefer call-site refactors for services that already have injectable constructors before rewriting their internals

---

## Audit Task 02: Magic number extraction
**Status:** Complete  
**Branch:** `codex/task-02-magic-numbers`  
**Changes:**
- Added shared scroll-capture thresholds for minimum alignment confidence and minimum meaningful displacement, and replaced the duplicated `0.35` / displacement-threshold call sites across the engine, automatic fallback logic, and displacement helper
- Replaced raw CGEvent scroll phase integers in the default scroll driver with a named `ScrollGesturePhase` enum
- Extracted duplicated annotation drawing constants for line width, arrowhead length, and highlight opacity so the live overlay and saved-image rendering paths share one source of truth
- Revalidated with `swift build`, `swiftlint`, and `swift test` (460 tests passing)

**Decisions Made:**
- Keep the task limited to duplicated behavioral thresholds and raw event phase values; do not sweep unrelated `12` literals that represent different concepts like sticky-header detection or UI spacing
- Reuse the same confidence threshold for the displacement helper's vision fallback so confidence acceptance and fallback confidence stay aligned by construction
- Limit the `AnnotationOverlay` cleanup to rendering constants that were duplicated between preview and save paths, rather than turning layout values into a broad style-token pass

---

## Audit Task 01: Lint suppression removal
**Status:** Complete  
**Branch:** `task-01-lint-suppression`  
**Changes:**
- Removed every `swiftlint:disable` / `swiftlint:enable` directive from `Caloura/`
- Split scroll-capture source into focused files for AX bridges, protocols, engine flow, automatic/manual capture logic, accessibility helpers, bitmap preparation, displacement analysis, stitching, and geometry
- Replaced the AX CoreFoundation bridge force casts with guarded `unsafeBitCast(...)` wrappers and replaced `PIIDetector`'s forced regex initialization with fail-fast compiled patterns
- Refactored `CapturePipeline.captureArea()` into smaller helpers, moved the welcome tab view out of `PreferencesView.swift`, and updated scroll-capture tests plus production call sites for the new request/settling parameter objects
- Revalidated with `swift build`, `swiftlint`, and `swift test` (460 tests passing)

**Decisions Made:**
- Keep the task strictly scoped to removing source suppressions and the minimum refactors needed to satisfy that cleanup; do not expand into broader warning-reduction work outside the affected surfaces
- Use parameter objects where signature width was the actual lint pressure point (`ScrollCaptureEngine.Request`, `ScrollSettleRequest`) instead of weakening access or reintroducing local suppression
- Preserve existing scroll-capture behavior by updating both production seams and synthetic-test doubles in the same refactor

---

## Task 13: Capture pipeline + command-surface refactor
**Status:** Complete  
**Branch:** `codex/task-13-post-grant-fix`  
**Changes:**
- Extracted capture orchestration collaborators: `CaptureRequestResolver`, `CaptureDistributionService`, `CaptureEnrichmentService`, and `AppCommandController`
- Moved history-editing writes behind explicit `AppState` mutation APIs and updated `HistoryView` plus capture enrichment paths to stop mutating persistence and embedding state directly from views
- Unified last-capture distribution actions with the same shared distribution path used by quick actions, and added characterization coverage for copy/save behavior plus the new `AppState` mutations
- Removed dead `CaptureWindow.swift`, aligned `Package.swift` to `KeyboardShortcuts` 2.4.0, and regenerated `Caloura.xcodeproj` after the file deletion so Xcode builds stayed in sync
- Revalidated the refactor with `swift build`, `swiftlint`, `swift test --enable-code-coverage`, and `xcodebuild test -only-testing:CalouraSystemTests`

**Decisions Made:**
- Keep the permission coordinator refactor separate from the active permission-loop work; this slice focused on capture/runtime seams, history ownership, and dead-code cleanup only
- Prefer sendable dependency bundles over `@unchecked Sendable` when moving enrichment work behind async coordinators
- Treat Xcode project regeneration as part of dead-code removal, not just new-file additions


## Task 10: Capture overlay + freeze snapshot hardening
**Status:** Complete  
**Branch:** `codex/task-10-capture-overlay-hardening`  
**Changes:**
- Replaced area/scroll frozen-background sourcing with a dedicated `ScreenCaptureKit` display snapshot path that excludes Caloura via `SCContentFilter(display:excludingApplications:exceptingWindows:)`
- Moved shared selection overlays off `.screenSaver` semantics to overlay-window level while keeping them as non-activating panels for immediate area/fullscreen selection input
- Excluded Caloura from the system window picker configuration so it cannot be selected or reflected by the native `SCContentSharingPicker`
- Added focused coverage for the new picker exclusion, the async freeze snapshot pipeline hook, and the overlay panel configuration
- Verified the touched paths with a targeted `xcodebuild test` slice instead of a full-suite run to keep validation/log volume tight during capture iteration

**Decisions Made:**
- Keep the instant-overlay UX and harden the frozen background source instead of regressing to a live-only or freeze-first area capture flow
- Treat display-filtered SCK screenshots that exclude Caloura as the safe freeze path; do not fall back to generic fullscreen snapshots once overlays are visible
- Keep validation narrow during capture-pipeline work until the implementation stabilizes, then expand only if the touched slice surfaces regressions

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

## Task 11: Install-first onboarding + DMG distribution
**Status:** Complete  
**Branch:** codex/task-11-install-first-onboarding  
**Changes:**
- Replaced the old `AppMover` alert + permission wizard with an install-first onboarding flow that gates startup on `/Applications`, drives the first session to the first capture CTA, and revalidates Screen Recording only after explicit user action or return from System Settings
- Split Screen Recording status into `denied`, `grantedNeedsValidation`, `working`, `needsRelaunch`, `staleRecord`, and `repairing`, keeping stale-copy detection inside `PermissionCoordinator` instead of mixing it into install flow
- Added lightweight contextual onboarding tips for history, edits, scroll capture, and sharing after activation
- Extended release/publish/public-QA scripts to produce a notarized DMG for manual download while keeping the ZIP path for Sparkle
- Updated README + public-download runbook and added Task 11 spec

**Decisions Made:**
- First-run users launched outside `/Applications` are blocked on install and do not proceed into permission setup or capture registration
- Passive CoreGraphics grant is no longer treated as “working” for the current app copy until interactive ScreenCaptureKit validation succeeds
- Manual download distribution is now DMG-first; Sparkle remains ZIP-backed

---

## Task 12: Screen Recording recovery + neutral DMG surface
**Status:** Complete  
**Branch:** `codex/task-12-screen-recording-recovery`  
**Changes:**
- Reworked Screen Recording onboarding so passive identity mismatches no longer trigger stale-copy repair on launch; only explicit live validation failures can produce `staleRecord`
- Replaced the old shareable-content permission probe with a minimal `SCScreenshotManager.captureImage(in:)` probe that distinguishes `authorized`, `userDeclined`, and `transientFailure`
- Added silent priming for already-granted Screen Recording on the first-capture screen and auto-resume of the pending first capture after System Settings return
- Swapped the DMG install window background from the app icon to a dedicated neutral light PNG asset and made the release script fail if that asset is missing
- Added focused tests for passive mismatch handling, post-settings live validation, typed SCK probe behavior, and the release script’s DMG background source

**Decisions Made:**
- Fingerprint mismatches remain advisory until the installed app actually fails a live capture validation path
- Background/onboarding permission probes must never permanently disable SCK for later capture attempts
- The DMG surface should stay plain and professional: neutral light background, same fixed drag-to-Applications layout

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

## Task 13: Screen Recording post-grant detection fix
**Status:** Complete
**Branch:** codex/task-13-post-grant-fix
**Changes:**
- Reworked post-Settings Screen Recording revalidation so `PermissionCoordinator` no longer waits for `CGPreflightScreenCaptureAccess()` to flip before attempting live SCK validation
- Added recent permission-request session tracking, current-process live-validation caching, and one-time pending-capture resume across automatic relaunch
- Updated onboarding and launch flow so stale in-process CG results keep the user in the waiting path instead of bouncing back to the grant screen
- Tightened capture error classification so stale CG false no longer turns transient post-grant capture failures into `.noPermission`
- Stopped showing the repaired/completed onboarding state for `grantedNeedsValidation`, and kept same-copy stale CG false in the validation/repair path instead of reopening System Settings immediately
- Narrowed stale-CG suppression so historical “last working” state no longer blocks a fresh `CGRequestScreenCaptureAccess()` prompt after TCC reset, while the one auto-relaunch path recreates the recent request session in memory
- Updated README, CLAUDE rules, and lessons to treat CG as coarse and SCK as authoritative after an explicit grant attempt

**Decisions Made:**
- Use one automatic self-relaunch only as the last resort after a 10s post-Settings grace window
- Resume the pending first capture automatically after that relaunch instead of dumping the user back into generic onboarding

---

## Task 07: Test flakiness hardening
**Status:** Complete
**Branch:** codex/task-07-test-flakiness
**Changes:**
- Replaced timing-based synchronization in flaky capture and scroll tests with deterministic async gating via `AsyncGate`
- Routed deferred-history waits and window-picker readiness checks through the shared polling helper instead of ad hoc `Task.sleep` loops
- Increased the named flaky poll timeouts called out by the audit plan and kept `pollUntil(...)` fail-fast on timeout
- Added fixture-level restoration for `AppSettings.shared.activePreset`, `AppState.shared.statusMessage`, and `URLSchemeHandler.lastHandledDate` to stop global state leakage between tests
- Added a DEBUG-only `URLSchemeHandler.setLastHandledDateForTesting(_:)` seam so tests can restore throttle state without reopening access control

**Decisions Made:**
- Prefer explicit gates and expectations over sub-200ms sleeps for async test ordering
- Restore shared singleton-backed test state in `tearDown()` instead of scattered per-test teardown blocks

---

## Task 08: ScrollCapture decomposition
**Status:** Complete
**Branch:** codex/task-08-scroll-decompose
**Changes:**
- Moved the shared scroll-capture enums, frame/viewport models, AX handle wrappers, error type, and protocols into [ScrollCaptureTypes.swift](/Users/b/Caloura/Caloura/Capture/ScrollCaptureTypes.swift)
- Removed the now-redundant [ScrollCaptureAXHandles.swift](/Users/b/Caloura/Caloura/Capture/ScrollCaptureAXHandles.swift) and [ScrollCaptureProtocols.swift](/Users/b/Caloura/Caloura/Capture/ScrollCaptureProtocols.swift) files
- Reduced [ScrollCaptureEngine.swift](/Users/b/Caloura/Caloura/Capture/ScrollCaptureEngine.swift) to engine-specific request/session/result orchestration only
- Regenerated [Caloura.xcodeproj/project.pbxproj](/Users/b/Caloura/Caloura.xcodeproj/project.pbxproj) so the tracked Xcode project matches the source-file rename and deletions

**Decisions Made:**
- Centralize reusable scroll-capture declarations in one dedicated types file instead of spreading them across a protocol file and an AX-handle file
- Leave engine-only request/session/result helpers nested on `ScrollCaptureEngine` so the new types file stays limited to shared declarations

---

## Task 09: Security audit
**Status:** Complete
**Branch:** codex/task-09-security
**Changes:**
- Added [audit-09-security.md](/Users/b/Caloura/codex/tasks/audit-09-security.md) covering crypto, license, PII, entitlements, and build-config review
- Rated one High-severity licensing area and four lower-severity areas with concrete evidence from source files
- Verified from code inspection that release builds require signed entitlements and do not use the configured license key value in any repo-local signing path

**Decisions Made:**
- Treat the legacy activation reconstruction path and defaults-backed trial anchor as one release-blocking licensing area
- Record the configured entitlement key as provenance-unverified rather than calling it definitively public from static code inspection alone

---

## Task 10: Performance & memory audit
**Status:** Complete
**Branch:** codex/task-10-performance
**Changes:**
- Added [audit-10-performance.md](/Users/b/Caloura/codex/tasks/audit-10-performance.md) covering scroll-capture memory, history scaling, thumbnail caching, embedding search, debounce behavior, and startup blocking
- Cached shared `NLEmbedding` instances in [EmbeddingEngine.swift](/Users/b/Caloura/Caloura/Processing/EmbeddingEngine.swift) and changed [EmbeddingStore.swift](/Users/b/Caloura/Caloura/Models/EmbeddingStore.swift) to keep only the bounded top-K matches instead of sorting every candidate
- Moved semantic-search work off the UI task path and wrapped thumbnail decoding in an autorelease pool in [HistoryView.swift](/Users/b/Caloura/Caloura/UI/HistoryView.swift)
- Reduced scroll-capture peak memory by wrapping frame preparation in autorelease pools and removing the stitched-canvas copy in [ScrollCaptureHelpers+Stitching.swift](/Users/b/Caloura/Caloura/Capture/ScrollCaptureHelpers+Stitching.swift)
- Replaced raw `NSApp.activate(...)` callsites in the AppKit capture path with `NSApplication.shared.activate(...)` so SwiftPM window-capture tests no longer trap on a nil app singleton
- Added targeted regression coverage for top-K embedding ordering in [EmbeddingStoreTests.swift](/Users/b/Caloura/CalouraTests/ProcessingTests/EmbeddingStoreTests.swift)

**Decisions Made:**
- Treat startup history/embedding hydration as a documented medium-severity finding rather than changing launch semantics in the same task
- Keep the history-scaling item as an architectural finding because the current 50-item cap makes pagination a product-scope change, not a low-risk optimization
- Use `swift test --parallel --num-workers 1` for the final full-suite validation because the default SwiftPM driver continued emitting runner-level signal errors around otherwise-passing AppKit tests, while the one-worker run completed all 466 tests cleanly

---

## Task 11: Dead code detection
**Status:** Complete
**Branch:** codex/task-11-dead-code
**Changes:**
- Added [audit-11-dead-code.md](/Users/b/Caloura/codex/tasks/audit-11-dead-code.md) documenting the method audit, type-alias audit, model-property audit, `KeychainHelper` lifecycle, and `UITestHostWindowController` production-build check
- Removed confirmed dead API from [AppState.swift](/Users/b/Caloura/Caloura/Models/AppState.swift), [CapturePipeline.swift](/Users/b/Caloura/Caloura/App/CapturePipeline.swift), and [ProcessedScreenshot.swift](/Users/b/Caloura/Caloura/Models/ProcessedScreenshot.swift)
- Updated [CapturePipelineTestHelpers.swift](/Users/b/Caloura/CalouraTests/Helpers/CapturePipelineTestHelpers.swift) to keep the test save-file seam local instead of routing it through dead `CapturePipeline` initializer surface
- Wrapped [UITestHostWindowController.swift](/Users/b/Caloura/Caloura/App/UITestHostWindowController.swift) in `#if DEBUG` and switched [CalouraApp.swift](/Users/b/Caloura/Caloura/App/CalouraApp.swift) to a DEBUG-only UI-test-host path so release builds no longer compile the host window controller
- Corrected the stale lifecycle comment in [KeychainHelper.swift](/Users/b/Caloura/Caloura/Security/KeychainHelper.swift) to reflect its live `HistoryCrypto` dependency

**Decisions Made:**
- Treat `AppState.upsertScreenshot(_:)`, `AppState.saveHistory()`, `CapturePipeline.SaveFileFn`, the matching test initializer parameter, `ProcessedScreenshotImageFormat`, and `ProcessedScreenshot.encodedImageData(format:)` as safe removals because repo-wide searches found no live callers beyond their own definitions or dead test seams
- Keep `ScreenshotItem.captureMode` in place even though it is not read by current UI logic, because it is part of the persisted history schema and removing it would change on-disk payloads without a clear migration payoff
- Keep `KeychainHelper.swift` because `HistoryCrypto` still uses it for the active history root key path and `AppSettings` still uses it for legacy license migration
- Re-use `swift test --parallel --num-workers 1` for the final green test signal because plain `swift test` still reproduced the known SwiftPM harness-level signal-11 failure during an otherwise-passing AppKit-heavy run

---

## Task 12: Test coverage gaps
**Status:** Complete
**Branch:** codex/task-12-test-coverage
**Changes:**
- Added [CaptureEnrichmentCoordinatorTests.swift](/Users/b/Caloura/CalouraTests/AppTests/CaptureEnrichmentCoordinatorTests.swift) with 5 focused tests covering FIFO scheduling, concurrency limits, duplicate deduplication, cancellation, and slot handoff behavior
- Added [CaptureDistributionServiceTests.swift](/Users/b/Caloura/CalouraTests/AppTests/CaptureDistributionServiceTests.swift) covering the save-path double-enrichment guard when preview state is already pending or OCR text is already present
- Added [AppCommandControllerTests.swift](/Users/b/Caloura/CalouraTests/AppTests/AppCommandControllerTests.swift) and introduced a narrow routing seam in [AppCommandController.swift](/Users/b/Caloura/Caloura/App/AppCommandController.swift) so command dispatch can be verified without driving `CapturePipeline.shared`
- Hardened [CaptureDistributionService.swift](/Users/b/Caloura/Caloura/App/CaptureDistributionService.swift) so save-triggered enrichment is skipped when OCR text is already attached to the screenshot
- Added [audit-12-coverage.md](/Users/b/Caloura/codex/tasks/audit-12-coverage.md) documenting new coverage, pre-existing `CapturePipeline.performCapture` error coverage, and UI-heavy areas that remain better suited to system tests
- Reworked [EmbeddingEngine.swift](/Users/b/Caloura/Caloura/Processing/EmbeddingEngine.swift) to keep cached `NLEmbedding` access behind a locked helper so the Xcode app-scheme build accepts the cache as concurrency-safe
- Replaced the exact-once background expectation in [CapturePipelineTests.swift](/Users/b/Caloura/CalouraTests/AppTests/CapturePipelineTests.swift) with a locked counter and final assertion so the plain `swift test` suite no longer aborts mid-run

**Decisions Made:**
- Use an injected closure bundle for `AppCommandController` routing instead of mocking entire singleton controllers, because the gap was command dispatch coverage, not UI presentation behavior
- Treat the `CaptureDistributionService` OCR-presence check as the minimal production fix for the known double-enrichment risk, rather than broadening preview-phase state modeling in the same task
- Keep `CapturePipeline.performCapture` error-path work documented rather than duplicated because `testPerformCapture_permissionError` and `testPerformCapture_genericError` already covered the requested cases before this task
- Fix the validation blockers inside the same task because both failures directly affected Task 12 sign-off: the plain `swift test` abort in `CapturePipelineTests` and the Xcode strict-concurrency rejection of cached embeddings

---

## Task 13: Build config & SwiftLint tightening
**Status:** Complete
**Branch:** codex/task-13-build-config
**Changes:**
- Tightened `.swiftlint.yml` so `line_length.error` is now `200` instead of `300`
- Updated [Package.swift](/Users/b/Caloura/Package.swift) to use `.swiftLanguageMode(.v6)` for both the app and test targets, aligning the package build with the Xcode project's Swift 6 setting
- Reworked the summary log construction in [CapturePerformanceRecorder.swift](/Users/b/Caloura/Caloura/App/CapturePerformanceRecorder.swift) so the file stays under the new hard line-length limit without tripping Swift 6 expression-type-check failures

**Decisions Made:**
- Kept `type_body_length` unchanged because the repo still has multiple warning-level offenders, so tightening it in Task 13 would create new lint debt instead of closing existing config drift
- Did not enable `trailing_comma` because a targeted lint run showed broad existing warning fallout across the repo, and did not enable `redundant_optional_initialization` because that rule is not available in the installed SwiftLint build
- Verified that [project.yml](/Users/b/Caloura/project.yml) and [Package.swift](/Users/b/Caloura/Package.swift) already agreed on the macOS 26 deployment target and package dependencies, and confirmed the Xcode project only contains the expected per-configuration `MACOSX_DEPLOYMENT_TARGET = 26.0` entries

---

<!-- Add new task entries above this line -->
