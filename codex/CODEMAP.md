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
   - `Caloura/Capture/PermissionCoordinator.swift` — permission status + UI model for onboarding.

4. **Processing + distribution**
   - `Caloura/Processing/ImageProcessor.swift` — image conversion/encoding.
   - `Caloura/Processing/SmartCropper.swift` — Vision-based smart crop.
   - `Caloura/Processing/OCREngine.swift` — OCR pipeline.
   - `Caloura/Distribution/ClipboardManager.swift` — clipboard copy.
   - `Caloura/Distribution/FileOrganizer.swift` — file saving / directory layout.
   - `Caloura/Distribution/MarkdownExporter.swift` — markdown output + citations.

5. **State + persistence**
   - `Caloura/Models/AppState.swift` — app state + encrypted history persistence.
   - `Caloura/Models/AppSettings.swift` — debounced settings + trial clock + license persistence.
   - `Caloura/Security/HistoryCrypto.swift` — AES-GCM encryption + permission audits.
   - `Caloura/Security/KeychainHelper.swift` — legacy keychain migration helper.

6. **UI surfaces**
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
- **Permission debugging**
  - `scripts/permission_diagnose.sh` — mixed-build identity issues.
- **Performance evidence**
  - `scripts/perf_audit.sh` — capture timing evidence and summaries.
  - `Caloura/App/PerformanceMetrics.swift` — in-app metric aggregation.

## Tests

- `CalouraTests/AppTests/*` — app state, onboarding, permission, performance.
- `CalouraTests/ContextTests/*` — presets + context detection.
- `CalouraTests/DistributionTests/*` — file organizer + markdown export.
- `CalouraTests/ProcessingTests/*` — image processing + smart crop.
- `CalouraTests/ModelTests/*` — model behavior + persistence.

## Build & Tooling

- `project.yml` — XcodeGen build definition (Xcode project is generated from this).
- `Package.swift` — SwiftPM support for `swift build` + `swift test`.
