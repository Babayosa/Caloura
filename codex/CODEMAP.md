# Caloura Code Map

## Overview
Caloura is a macOS menu-bar screenshot tool. The app routes user actions (menu-bar items, hotkeys, or URL scheme) into a central capture pipeline that performs captures, processing, distribution, and history persistence. Release confidence is enforced via scripts and CI gates (build, strict lint, tests, coverage thresholds).

## Top-Level Layout

- `Caloura/` — App sources (SwiftUI, AppKit, capture pipeline, processing, security)
- `CalouraTests/` — Unit tests by feature area (SwiftPM + Xcode)
- `CalouraSystemTests/` — Window/coordinator system tests (Xcode test plan only; not run by `swift test`)
- `CalouraUITests/` — XCUITest automation against the launched app
- `scripts/` — Release guard + QA + performance tools
- `.github/workflows/` — CI (build/lint/test/coverage), release guard, release smoke
- `project.yml` — XcodeGen source of truth
- `Caloura.xcodeproj/` — generated Xcode project (tracked; regenerate with `xcodegen generate` after adding files)
- `codex/` — scope, rules, context chain, task specs
- `tasks/` — runbooks, audits, and evidence checklists

## Core Runtime Flow

1. **Entry points**
   - `Caloura/App/CalouraApp.swift` — `@main` + app delegate; wires `StatusMessageRouter.sink`, permission refresh, hotkeys, URL scheme at launch.
   - `Caloura/App/TestEnvironment.swift` — detects XCTest-hosted runs and blocks launch side effects (onboarding, AppMover) inside test processes.
   - `Caloura/UI/MenuBarView.swift` — menu-bar actions.
   - `Caloura/App/URLSchemeHandler.swift` — `caloura://` automation routes.
   - `Caloura/HotKeys/HotKeyManager.swift` — hotkey bindings to notifications.
   - `Caloura/App/AppCommandController.swift` + `AppCommand.swift` — single command router: menu/hotkey/URL actions resolve to a `Routing` table of capture and copy/save commands.

2. **Capture orchestration** (`CapturePipeline` is a thin `@Observable` facade over extracted services)
   - `Caloura/App/CapturePipeline.swift` (+ `CapturePipeline+SessionState.swift`) — owns service wiring and session state; public seam for UI and command routing.
   - `Caloura/App/CaptureEntrypointService.swift` (+ `+OverlaySessions.swift`) — entry per capture mode: permission preflight, delayed-capture countdown, presents overlay/selection sessions.
   - `Caloura/App/CaptureRequestResolver.swift` — resolves `DetectedContext` + settings into the active `CapturePreset` and `CaptureContext`.
   - `Caloura/App/CaptureSessionCoordinators.swift` + `CaptureSessionState.swift` — area/fullscreen session coordinators (overlay presentation, crosshair/cursor session lifecycle, multi-screen ordering).
   - `Caloura/App/CaptureFreezeService.swift` — frozen-backdrop snapshot shown behind selection overlays.
   - `Caloura/App/CaptureExecutionService.swift` — executes the capture, runs processing, persists the artifact, owns failure handling/reset.
   - `Caloura/App/ScreenshotArtifactCoordinator.swift` — save/overwrite/copy of the produced artifact; deduplicates concurrent save requests.
   - `Caloura/App/CaptureDistributionService.swift` — post-capture clipboard/save/markdown/citation routing.
   - `Caloura/App/CaptureEnrichmentService.swift` + `CaptureEnrichmentCoordinator.swift` — deferred enrichment after capture: OCR, PII scan, embeddings, smart metadata; emits `CapturePreviewPhase` terminal states.
   - `Caloura/App/CaptureMetricsRecorder.swift`, `CapturePerformanceRecorder.swift`, `PerformanceMetrics.swift` — stage timing + percentile logging.
   - `Caloura/Capture/CaptureOverlayWindow.swift` + `CaptureOverlayWindowPool.swift` + `RegionSelectionView*.swift` — area capture selection overlays (pooled `NSPanel`s).
   - `Caloura/Capture/ScreenSelectionOverlayWindow.swift` + `ScreenSelectionView.swift` — multi-screen selection.
   - `Caloura/Capture/CaptureCursorController.swift` + `CaptureCrosshair*.swift` — reference-counted cursor/crosshair session control (see CLAUDE.md cursor rules).
   - `Caloura/Capture/WindowPickerManager.swift` (+ `+SystemPicker.swift`) — system window picker integration.

3. **Capture execution**
   - `Caloura/Capture/ScreenCaptureManager.swift` — ScreenCaptureKit primary (`+SCKCapture.swift`, incl. frozen-display one-shot stream), `screencapture` CLI fallback (`+CLICapture.swift`), permission probes (`+Permission.swift`, `+PermissionTools.swift`).

4. **Screen Recording permissions** (every flow: evidence acquisition → planner decision → step execution → gated publication)
   - `Caloura/Capture/PermissionStore.swift` — single owner of all durable (UserDefaults) + session permission state: last-working identity, pending capture resume, alert/relaunch cooldowns, request session, live-validated fingerprint, pinned diagnosis. `statusContext(for:at:)` gathers one evidence snapshot per evaluation (`PermissionStatusContext`).
   - `Caloura/Capture/PermissionStatusCore.swift` — pure rules: evidence snapshot → `ScreenRecordingState` + `PermissionUIModel` (guidance text, banners, messages).
   - `Caloura/Capture/PermissionRecoveryPlanner.swift` — pure decision table: (state × evidence × cooldowns) → `PermissionRecoveryStep` for the capture-failure and settings-return recovery flows; no side effects.
   - `Caloura/Capture/PermissionCoordinator.swift` — facade and the ONLY publication path: `publish(_:source:)` serializes flows, defers passive publications while a flow holds the gate, and preserves pinned diagnoses. Public API used by `CalouraApp`, `CapturePipeline`, `OnboardingView`, `AppCommandController`.
   - `Caloura/Capture/PermissionCoordinator+Publication.swift` — evidence acquisition (`refreshPassiveStatus(source:)`) + convenience publishers feeding the gate.
   - `Caloura/Capture/PermissionCoordinator+RecoveryExecution.swift` — serialized flow cores + executors for the planner's recovery steps (alerts, replayd repair, TCC reset, relaunch) via the injected effector closures.
   - `Caloura/Capture/PermissionIdentity.swift` + `PermissionIdentityProvider.swift` — signing-identity fingerprinting (stale-record detection keys on signing identity, never executable path).
   - `Caloura/Capture/PermissionCooldownPolicy.swift` — alert + auto-repair-relaunch cooldown thresholds.

5. **Context + presets**
   - `Caloura/Context/ContextDetector.swift` — frontmost-app category detection (bundle-ID map).
   - `Caloura/Context/PresetManager.swift` — preset persistence + category routing.
   - `Caloura/Models/CaptureContext.swift` — capture context model.

6. **Processing + distribution**
   - `Caloura/Processing/ImageProcessor.swift` — image conversion/encoding.
   - `Caloura/Processing/SmartCropper.swift` — Vision-based smart crop.
   - `Caloura/Processing/OCREngine.swift` — Vision OCR (text + bounding-box observations).
   - `Caloura/Processing/PIIDetector.swift` + `RedactionEngine.swift` — on-device PII detection + redaction rendering.
   - `Caloura/Processing/Beautifier.swift` + `Caloura/Models/BeautifyTheme.swift` — themed "Beautify" output.
   - `Caloura/Processing/EmbeddingEngine.swift` + `SmartMetadataGenerator.swift` — semantic-search embeddings + generated titles/tags.
   - `Caloura/Distribution/ClipboardManager.swift` — clipboard copy.
   - `Caloura/Distribution/FileOrganizer.swift` — file saving / directory layout (path-traversal safe, 0600/0700 permissions).
   - `Caloura/Distribution/MarkdownExporter.swift` — markdown output + citations.

7. **State + persistence**
   - `Caloura/Models/AppState.swift` (+ `AppState+History.swift`) — `@Observable` app state + encrypted history persistence and pruning.
   - `Caloura/Models/StatusMessageRouter.swift` — the Capture→App seam: Capture/ writes status messages to the router; `CalouraApp` wires `sink` into `AppState.statusMessage` once at startup, so Capture/ never imports `AppState`.
   - `Caloura/Models/AppSettings.swift` (+ `+License.swift`) — debounced settings + trial clock + license persistence.
   - `Caloura/Models/EmbeddingStore.swift` — `actor`; JSON+AES-GCM embedding persistence with disk I/O off the main actor.
   - `Caloura/Security/HistoryCrypto.swift` — AES-GCM encryption (HKDF purpose-derived keys, keychain-backed root key).
   - `Caloura/Security/KeychainHelper.swift` — non-interactive keychain read/write for the history root key.

8. **Licensing + updates**
   - `Caloura/App/LicenseManager.swift` (+ `+Shared.swift`) — license state and trial tracking.
   - `Caloura/App/LicenseEntitlementVerifier.swift` — signed-entitlement verification against the license worker.
   - `Caloura/App/UpdateManager.swift` (+ `+Shared.swift`, `+Sparkle.swift`) — Sparkle update integration.
   - `Caloura/App/AppMover.swift` — move-to-/Applications prompt (suppressed under `TestEnvironment`).

9. **UI surfaces**
   - `Caloura/UI/PreferencesView.swift` (+ `+Tabs.swift`, `+Welcome.swift`, `+WindowController.swift`) — settings tabs, license, updates.
   - `Caloura/UI/OnboardingView.swift` (+ `+Steps.swift`, `OnboardingFlowModel.swift`, `OnboardingPermissionPresentation.swift`) — onboarding steps + permission presentation.
   - `Caloura/UI/HistoryView.swift` (+ `+Components.swift`, `+WindowController.swift`, `HistorySearchModel.swift`) — history browser; `HistorySearchModel` caches the filtered result per (items, query, semantic) key.
   - `Caloura/UI/QuickAccessOverlay.swift` — post-capture floating preview/actions panel.
   - `Caloura/UI/AnnotationOverlay.swift` + `PinnedScreenshotWindow.swift` — annotate/pin flows.
   - `Caloura/UI/BeautifyPreviewOverlay.swift` + `RedactionReviewOverlay.swift` — beautify preview and PII redaction review.
   - `Caloura/UI/CountdownOverlay.swift` + `NagDialog.swift` — delayed capture + trial nag.
   - `Caloura/UI/SingleWindowPresenter.swift` — reusable single-instance window presenter.

## Release Confidence Loop

- **Guardrails**
  - `.github/workflows/release-guard.yml` — enforces tag/version parity.
  - `.github/workflows/release-smoke.yml` — release artifact smoke checks.
  - `scripts/release.sh` — guard-only mode and release packaging; `scripts/publish.sh` — full publish to GitHub Pages.
  - `scripts/release_ready.sh` — local pre-release gate (tests + coverage thresholds via `scripts/coverage_gate.py`).
  - `scripts/release_manifest.py` + `scripts/validate_appcast_against_manifest.py` — appcast/manifest parity + EdDSA validation.
  - `scripts/validate_release_build_settings.sh` — pre-build Release-settings validator.
- **Continuous checks**
  - `.github/workflows/ci.yml` — `macos-26` runner: xcodegen, SwiftPM tests, `swiftlint lint --strict`, xcodebuild tests with result bundle, `coverage_gate.py` thresholds (tool versions pinned in `scripts/ci_tool_versions.env`).
- **Public download QA**
  - `scripts/public_download_qa.sh` — verify artifact + onboarding/trial checks.
  - `tasks/public-download-qa-runbook.md` — step-by-step validation runbook.
- **Permission debugging**
  - `scripts/permission_diagnose.sh` — mixed-build identity issues.
- **Performance evidence**
  - `scripts/perf_audit.sh` — capture timing evidence and summaries.
  - `Caloura/App/PerformanceMetrics.swift` — in-app metric aggregation.
  - `tasks/security-performance-audit.md` — performance evidence checklist.

## Tests

- `CalouraTests/AppTests/*` — pipeline/services, permission coordinator flows, onboarding, license, URL scheme, diagnostics, performance contracts.
- `CalouraTests/CaptureTests/*` — permission machine, capture manager, overlay/cursor units.
- `CalouraTests/ContextTests/*` — presets + context detection.
- `CalouraTests/DistributionTests/*` — file organizer (incl. path-traversal cases) + markdown export.
- `CalouraTests/ProcessingTests/*` — image processing, smart crop, OCR, PII, beautify, embeddings.
- `CalouraTests/ModelTests/*` — model behavior + encrypted-history persistence/migration.
- `CalouraTests/SecurityTests/*` — HistoryCrypto/KeychainHelper.
- `CalouraTests/UITests/*` — view-model-level UI logic (history search/cache, perf baselines).
- `CalouraTests/InfraTests/*` — release-script and CI contract assertions.
- `CalouraTests/Helpers/*` — shared fixtures: pipeline harness, fake capture managers/sessions, async helpers, temp-file teardown helpers.
- `CalouraSystemTests/CaptureSystemTests.swift` — real-window coordinator/system behavior (skips multi-screen cases headless).
- `CalouraUITests/` — XCUITest against the launched app (`CALOURA_UI_TEST_HOST`).

## Build & Tooling

- `project.yml` — XcodeGen build definition (Xcode project is generated from this; `Caloura/Resources/` rides in the `sources:` path, Info.plist via `INFOPLIST_FILE`).
- `Package.swift` — SwiftPM support for `swift build` + `swift test` (CalouraTests only).
- `.swiftlint.yml` — lint config; CI runs `--strict`.
