# Caloura Code Map

## Overview
Caloura is a macOS menu-bar screenshot tool. The app routes user actions (menu-bar items, hotkeys, or URL scheme) into a central capture pipeline that performs captures, processing, distribution, and history persistence. Release confidence is enforced via scripts and a CI guard.

## Top-Level Layout

- `Caloura/` — App sources (SwiftUI, AppKit, capture pipeline, processing, security)
- `CalouraTests/` — Unit tests by feature area
- `scripts/` — Release guard + QA + performance tools
- `.github/workflows/` — CI release guard
- `project.yml` — XcodeGen source of truth
- `Caloura.xcodeproj/` — generated Xcode project (tracked)
- `codex/` — scope, rules, context chain, task specs
- `tasks/` — runbooks, audits, and evidence checklists

## Core Runtime Flow

1. **Entry points**
   - `Caloura/App/CalouraApp.swift` — `@main` + app delegate.
   - `Caloura/UI/MenuBarView.swift` — menu-bar actions.
   - `Caloura/App/URLSchemeHandler.swift` — `caloura://` automation routes.
   - `Caloura/HotKeys/HotKeyManager.swift` — hotkey bindings to notifications.

2. **Capture orchestration**
   - `Caloura/App/CapturePipeline.swift` — coordinates capture flow, overlays, delays, and post-capture actions.
   - `Caloura/Capture/CaptureOverlayWindow.swift` + `Caloura/Capture/RegionSelectionView.swift` — area capture selection.
   - `Caloura/Capture/ScreenSelectionOverlayWindow.swift` + `Caloura/Capture/ScreenSelectionView.swift` — multi-screen selection.
   - `Caloura/Capture/WindowPickerManager.swift` — system window picker integration.

3. **Capture execution**
   - `Caloura/Capture/ScreenCaptureManager.swift` — ScreenCaptureKit primary, `screencapture` CLI fallback, CoreGraphics fallback.

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
   - `Caloura/Context/*` — preset definitions and context detection.
   - `Caloura/Models/CaptureContext.swift` — capture context model.

6. **Processing + distribution**
   - `Caloura/Processing/ImageProcessor.swift` — image conversion/encoding.
   - `Caloura/Processing/SmartCropper.swift` — Vision-based smart crop.
   - `Caloura/Processing/OCREngine.swift` — OCR pipeline.
   - `Caloura/Distribution/ClipboardManager.swift` — clipboard copy.
   - `Caloura/Distribution/FileOrganizer.swift` — file saving / directory layout.
   - `Caloura/Distribution/MarkdownExporter.swift` — markdown output + citations.

7. **State + persistence**
   - `Caloura/Models/AppState.swift` — app state + encrypted history persistence.
   - `Caloura/Models/AppSettings.swift` — debounced settings + trial clock + license persistence.
   - `Caloura/Security/HistoryCrypto.swift` — AES-GCM encryption + permission audits.
   - `Caloura/Security/KeychainHelper.swift` — legacy keychain migration helper.

8. **Licensing + updates**
   - `Caloura/App/LicenseManager.swift` — license state and trial tracking.
   - `Caloura/App/UpdateManager.swift` — Sparkle update integration.

9. **UI surfaces**
   - `Caloura/UI/PreferencesView.swift` — settings tabs, license, updates.
   - `Caloura/UI/OnboardingView.swift` + `Caloura/UI/OnboardingFlowModel.swift` — onboarding steps.
   - `Caloura/UI/HistoryView.swift` — history browser (encrypted items).
   - `Caloura/UI/AnnotationOverlay.swift` + `Caloura/UI/PinnedScreenshotWindow.swift` — annotate/pin flows.
   - `Caloura/UI/CountdownOverlay.swift` + `Caloura/UI/NagDialog.swift` — delayed capture + trial nag.

## Release Confidence Loop

- **Guardrails**
  - `.github/workflows/release-guard.yml` — enforces tag/version parity.
  - `scripts/release.sh` — guard-only mode and release packaging.
- **Continuous checks**
  - `.github/workflows/ci.yml` — PR/push validation (SwiftPM + Xcode tests).
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

- `CalouraTests/AppTests/*` — app state, onboarding, permission, performance.
- `CalouraTests/AppTests/PerformanceMetricsTests.swift` — perf stage-name contract tests.
- `CalouraTests/ContextTests/*` — presets + context detection.
- `CalouraTests/DistributionTests/*` — file organizer + markdown export.
- `CalouraTests/ProcessingTests/*` — image processing + smart crop.
- `CalouraTests/ModelTests/*` — model behavior + persistence.

## Build & Tooling

- `project.yml` — XcodeGen build definition (Xcode project is generated from this).
- `Package.swift` — SwiftPM support for `swift build` + `swift test`.
