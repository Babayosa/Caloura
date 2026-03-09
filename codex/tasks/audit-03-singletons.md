# Audit 03: Singleton Dependency Audit

## Scope
- Catalog all custom `.shared` singletons in `Caloura/`
- Count distinct accessing files across `Caloura/` and `CalouraTests/`
- Classify each singleton by refactor urgency
- Cross-reference the known global-state test pollution issues

## Summary
- Cataloged 25 custom `.shared` singletons.
- Highest fanout singletons are `AppSettings.shared` (18 files), `AppState.shared` (11), `AppCommandRouter.shared` (7), `PermissionCoordinator.shared` (6), and `PresetManager.shared` / `ScreenCaptureManager.shared` / `ScreenshotArtifactCoordinator.shared` (4 each).
- The architectural debt is concentrated in 6 root-level mutable services, not in every singleton equally.
- Most remaining `.shared` usages are UI presenters, private caches, or thin wrappers over system-global APIs.

## Tiering Criteria
- Tier 1 — Refactor now: mutable root service with cross-feature fanout and a clear testability or state-isolation cost today.
- Tier 2 — Refactor when touched: stateful or app-scoped singleton with a reasonable existing seam, but not the main blocker right now.
- Tier 3 — Acceptable: private cache, OS-global wrapper, or single-window presenter with minimal domain state.

## Full Catalog

Counts below are distinct files referencing `Type.shared` across `Caloura/` and `CalouraTests/`.

| Singleton | Definition | Access count | Tier | Notes |
| --- | --- | ---: | --- | --- |
| `AppSettings.shared` | `Caloura/Models/AppSettings.swift:19` | 18 | Tier 1 | Highest fanout mutable settings store; views and services both reach it directly. |
| `AppState.shared` | `Caloura/Models/AppState.swift:47` | 11 | Tier 1 | Global mutable runtime state; direct writes still exist in views, overlays, and permission code. |
| `AppCommandRouter.shared` | `Caloura/App/AppCommand.swift:27` | 7 | Tier 1 | Global command bus for menu bar, hotkeys, onboarding, URL scheme, and tests. |
| `PermissionCoordinator.shared` | `Caloura/Capture/PermissionCoordinator.swift:165` | 6 | Tier 1 | Shared permission state is read from app startup, onboarding, commands, and capture failure paths. |
| `CapturePipeline.shared` | `Caloura/App/CapturePipeline.swift:10` | 2 | Tier 1 | Low file count but very high impact: command routing and quick-access actions both bypass injection and hit the global orchestrator directly. |
| `ScreenshotArtifactCoordinator.shared` | `Caloura/App/CapturePipeline+Distribution.swift:7` | 4 | Tier 1 | Global save/overwrite coordinator mutates `AppState` and reads `AppSettings` from multiple UI controllers. |
| `PresetManager.shared` | `Caloura/Context/PresetManager.swift:57` | 4 | Tier 2 | Read-mostly lookup service; moderate fanout, but low mutation risk. |
| `ScreenCaptureManager.shared` | `Caloura/Capture/ScreenCaptureManager.swift:133` | 4 | Tier 2 | Already protocolized in core capture paths; remaining `.shared` usage is mostly default wiring. |
| `OnboardingTipsController.shared` | `Caloura/UI/OnboardingView.swift:337` | 3 | Tier 2 | App-scoped presenter with persistent settings side effects; moderate UI coupling. |
| `LicenseManager.shared` | `Caloura/App/LicenseManager+Shared.swift:4` | 2 | Tier 2 | Shared root license manager, but the underlying type already takes `AppSettings` in its initializer. |
| `CapturePerformanceRecorder.shared` | `Caloura/App/CapturePerformanceRecorder.swift:45` | 2 | Tier 2 | Global metrics recorder; low business risk, but still an app-scoped mutable service. |
| `SmartMetadataGenerator.shared` | `Caloura/Processing/SmartMetadataGenerator.swift:16` | 2 | Tier 2 | Stateless service with an existing `MetadataGenerating` protocol; easy to inject later. |
| `PreferencesWindowController.shared` | `Caloura/UI/PreferencesView+WindowController.swift:5` | 2 | Tier 2 | Imperative window presenter; not urgent, but root-owned presentation would simplify command tests. |
| `QuickAccessOverlay.shared` | `Caloura/UI/QuickAccessOverlay.swift:8` | 2 | Tier 2 | Overlay manager still reaches `AppState.shared` and `CapturePipeline.shared` internally. |
| `BeautifyPreviewController.shared` | `Caloura/UI/BeautifyPreviewOverlay.swift:6` | 2 | Tier 2 | Presenter is fine, but the view still reaches shared state and save services. |
| `RedactionReviewController.shared` | `Caloura/UI/RedactionReviewOverlay.swift:6` | 2 | Tier 2 | Similar to beautify: mostly presenter debt plus global state access from the review flow. |
| `UpdateManager.shared` | `Caloura/App/UpdateManager+Shared.swift:9` | 1 | Tier 2 | Only one external user today, but it is still an app-owned mutable object that can be passed from composition root. |
| `PermissionIdentityProvider.shared` | `Caloura/Capture/PermissionIdentityProvider.swift:6` | 1 | Tier 2 | Narrow fanout and already injectable, but still default-wired as a global dependency. |
| `WindowPickerManager.shared` | `Caloura/Capture/WindowPickerManager.swift:29` | 1 | Tier 2 | Mutable async coordinator with continuations and timeout state; already has an initializer seam. |
| `PinnedScreenshotManager.shared` | `Caloura/UI/PinnedScreenshotWindow.swift:8` | 1 | Tier 2 | Imperative presenter; low fanout, but still participates in shared `AppState` writes. |
| `CountdownOverlay.shared` | `Caloura/UI/CountdownOverlay.swift:15` | 1 | Tier 2 | App-scoped overlay presenter; low fanout and low risk, but still global UI coordination. |
| `HotKeyManager.shared` | `Caloura/HotKeys/HotKeyManager.swift:6` | 1 | Tier 3 | Thin root-scoped wrapper around global OS hotkey registration. |
| `UITestHostWindowController.shared` | `Caloura/App/UITestHostWindowController.swift:9` | 1 | Tier 3 | UI-test harness controller, guarded by `CALOURA_UI_TEST_HOST`; not production architecture debt. |
| `HistoryThumbnailCache.shared` | `Caloura/UI/HistoryView.swift:5` | 1 | Tier 3 | Private file-scoped `NSCache`; this is a local implementation detail, not app-wide coupling. |
| `SystemWindowSharingPicker.shared` | `Caloura/Capture/WindowPickerManager+SystemPicker.swift:5` | 1 | Tier 3 | Thin wrapper over `SCContentSharingPicker.shared`, which is already system-global. |

## Tier 1 Blueprints

### 1. `AppSettings.shared`
- Why now:
  It has the highest fanout in the repo and already leaks into tests through `activePreset`.
- Existing seam to build on:
  `LicenseManager`, `UpdateManager`, `CapturePipeline`, and `ScreenshotArtifactCoordinator` already accept `AppSettings` in their initializers.
- DI blueprint:
  Introduce small consumer-facing protocols instead of one giant `AppSettingsProtocol`.
  Start with `CaptureSettings`, `OnboardingSettings`, and `BeautifySettings`.
  Pass a concrete `AppSettings` instance from `CalouraApp` into SwiftUI roots and imperative controllers.
  Remove direct `AppSettings.shared` access from `URLSchemeHandler`, `PreferencesView`, and overlay views by passing settings in.
- Test double pattern:
  Use in-memory `UserDefaults` backed `AppSettings(defaults:)` where possible.
  For narrower consumers, use protocol spies instead of the full settings object.

### 2. `AppState.shared`
- Why now:
  It is the other major mutable global, and it already leaks into tests through `statusMessage`.
- Existing seam to build on:
  `CapturePipeline`, `ScreenshotArtifactCoordinator`, and `HistoryView` already take `AppState` explicitly in some paths.
- DI blueprint:
  Split consumers by responsibility: `StatusMessageSink`, `LastCaptureProviding`, `HistoryStore`, and `PreviewPhaseStore`.
  Inject those into `AppCommandController`, `QuickAccessOverlay`, `BeautifyPreviewView`, `RedactionReviewController`, and `PinnedScreenshotManager`.
  Keep one concrete `AppState` instance at app root and pass it down instead of re-looking it up globally.
- Test double pattern:
  Use lightweight spies for `StatusMessageSink` and `LastCaptureProviding`.
  Reserve concrete `AppState(defaults:historyStoreURL:)` only for persistence-heavy tests.

### 3. `AppCommandRouter.shared`
- Why now:
  It is the command spine for hotkeys, menu bar actions, onboarding, and URL scheme routing.
  Global handler registration also makes lifecycle mistakes easy to hide.
- Existing seam to build on:
  `AppCommandController` already centralizes command handling.
- DI blueprint:
  Add an `AppCommandRouting` protocol with `dispatch`, `addHandler`, and `removeHandler`.
  Let `CalouraApp` own one router instance and inject `dispatch` or the router itself into `MenuBarView`, `HotKeyManager`, `URLSchemeHandler`, and `OnboardingWindowController`.
  Keep handler lifetime tied to app composition rather than static global state.
- Test double pattern:
  Use a `CommandCollector` that records dispatched commands and exposes explicit subscriptions for tests.

### 4. `PermissionCoordinator.shared`
- Why now:
  Onboarding, startup, and capture-failure recovery all depend on the same shared mutable permission state.
- Existing seam to build on:
  `PermissionCoordinator` already has a dependency-injected initializer with closures for its external effects.
- DI blueprint:
  Define a `PermissionCoordinating` protocol exposing `permissionUIModel`, `refreshPassiveStatus`, `primeIfPermissionGranted`, `runUserInitiatedValidation`, and `handleCapturePermissionFailure`.
  Inject it into `OnboardingView`, `CalouraApp`, and `AppCommandController` from the app root.
  Leave the current constructor intact and replace `.shared` lookups at call sites first.
- Test double pattern:
  Wrap the existing initializer in a `FakePermissionCoordinator` that stores a mutable `PermissionUIModel` and scripted async responses.

### 5. `CapturePipeline.shared`
- Why now:
  This is the central orchestration object, and direct singleton access from `AppCommandController` and `QuickAccessOverlay` undermines the DI work already done inside the pipeline.
- Existing seam to build on:
  `CapturePipeline` already has a large testing initializer and injected collaborators.
- DI blueprint:
  Define a `CaptureCommandHandling` protocol for the methods the outside world actually calls.
  Inject that protocol into `AppCommandController` and into the quick-access overlay action path.
  Keep `CalouraApp` responsible for constructing the single concrete pipeline.
- Test double pattern:
  Use a `CaptureCommandSpy` with recorded invocations for command-routing and overlay tests.

### 6. `ScreenshotArtifactCoordinator.shared`
- Why now:
  Save/overwrite logic is still reached globally from multiple UI flows and carries hidden `AppState` and `AppSettings` side effects.
- Existing seam to build on:
  The type already has an injected initializer for `appState`, `settings`, file saves, and save panels.
- DI blueprint:
  Introduce `ScreenshotArtifactSaving` with `saveCapture` and `saveDerivedCapture`.
  Inject it into `CapturePipeline`, `AppCommandController`, `BeautifyPreviewView`, and `RedactionReviewController`.
  Keep one concrete coordinator at the app root so save policy remains centralized without being globally addressed.
- Test double pattern:
  Use an `ArtifactSaverSpy` that records requested saves and can return deterministic URLs or errors.

## Known Test Pollution Cross-Reference

### `AppSettings.shared.activePreset`
- Evidence:
  `CalouraTests/AppTests/URLSchemeHandlerTests.swift` saves and restores `AppSettings.shared.activePreset` around URL handling tests.
- Audit implication:
  This confirms `AppSettings.shared` is not just a style issue; it is already leaking mutable global state between tests.

### `AppState.shared.statusMessage`
- Evidence:
  `CalouraTests/CaptureTests/ScreenCaptureManagerPermissionTests.swift` saves and restores `AppState.shared.statusMessage`.
- Audit implication:
  This confirms `AppState.shared` is acting as a write-anywhere global status bus and deserves immediate extraction pressure.

### `URLSchemeHandler.lastHandledDate`
- Evidence:
  `CalouraTests/AppTests/URLSchemeHandlerTests.swift` resets `URLSchemeHandler.lastHandledDate` between tests.
- Audit implication:
  This is not part of the 25-singleton catalog, but it is the same hidden-global-state pattern.
  Any refactor of `AppCommandRouter.shared` and `AppSettings.shared` on the URL path should also extract throttle state into an injected collaborator or resettable value object.

## Recommended Order
1. Remove `AppSettings.shared` and `AppState.shared` from UI/controller edges first; that addresses the two known test pollution issues immediately.
2. Replace `CapturePipeline.shared` and `ScreenshotArtifactCoordinator.shared` at command and overlay boundaries next; the core implementations already support injection.
3. Refactor `PermissionCoordinator.shared` and `AppCommandRouter.shared` once app-root composition owns the primary state and command graph.
