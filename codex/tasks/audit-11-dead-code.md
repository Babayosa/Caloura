# Task 11: Dead Code Detection

## Scope

Audited the requested surfaces with repo-wide `rg` checks against `Caloura/` and
`CalouraTests/`:

1. `ScreenCaptureManager`, `AppState`, and `CapturePipeline` methods
2. `CapturePipeline` closure type aliases
3. `ProcessedScreenshot`, `ScreenshotItem`, and `CaptureContext` properties
4. `KeychainHelper.swift` lifecycle
5. `UITestHostWindowController` production-build inclusion

## Confirmed Removals

Removed these confirmed dead items:

| Item | Evidence | Action |
| --- | --- | --- |
| `AppState.upsertScreenshot(_:)` | `rg -n "\\bupsertScreenshot\\(" Caloura CalouraTests` returned only the definition in `AppState.swift` | Removed |
| `AppState.saveHistory()` | `rg -n "\\bsaveHistory\\(" Caloura CalouraTests` returned only the definition in `AppState.swift` | Removed |
| `CapturePipeline.SaveFileFn` | Only used as a dead test-init seam; no production storage or call path in `CapturePipeline` | Removed from `CapturePipeline` |
| `CapturePipeline.init(... saveFile: ...)` test seam | Parameter was never read inside the initializer body | Removed from `CapturePipeline` and test helper updated |
| `ProcessedScreenshotImageFormat` | `rg -n "\\bProcessedScreenshotImageFormat\\b" Caloura CalouraTests` returned only the enum definition and `encodedImageData(format:)` | Removed |
| `ProcessedScreenshot.encodedImageData(format:)` | `rg -n "\\bencodedImageData\\(" Caloura CalouraTests` returned only the method definition | Removed |

## Method Audit

### `CapturePipeline`

No dead methods remain in the audited surface. Every method defined in
`CapturePipeline.swift`, `CapturePipeline+EntryPoints.swift`,
`CapturePipeline+ScrollCapture.swift`, `CapturePipeline+FreezeCapture.swift`, and
`CapturePipeline+Distribution.swift` has at least one external caller in another
source file or in tests.

Representative external callers:

- `captureArea()`, `captureWindow()`, `captureFullscreen()`, `captureRepeat()`,
  `captureDelayed(...)`, `cancelDelayedCapture()` are routed from
  `AppCommandController.swift` and exercised in `CapturePipelineEntryPointTests.swift`
- `performQuickAction(...)` is called from `QuickAccessOverlay.swift`
- `captureFailureStatusMessage(...)` / `captureFailureLogMessage(...)` are used by
  `CapturePipeline+ScrollCapture.swift`
- overlay/session mutation helpers are used from `CapturePipeline+EntryPoints.swift`
  and `CapturePipeline+ScrollCapture.swift`

### `ScreenCaptureManager`

No dead methods remain in the audited surface. All requested methods have at
least one caller outside their defining file, either from production code,
extension files, or tests.

Representative external callers:

- permission methods are used by `PermissionCoordinator.swift`
- capture conversion helpers are used by `ScreenCaptureManager+SCKCapture.swift`
  and `ScreenCaptureManager+CLICapture.swift`
- `resetSCKState()` and `prewarmWindowShareableContent()` are used by
  `CalouraApp.swift`

### `AppState`

Two dead methods were removed:

- `upsertScreenshot(_:)`
- `saveHistory()`

All remaining audited methods have live callers in production or tests.

## `CapturePipeline` Type Alias Audit

Of the original closure aliases in `CapturePipeline.swift`, only `SaveFileFn`
was dead in the `CapturePipeline` target. The remaining aliases still back live
dependency injection paths or test construction:

- request resolution: `DetectContextFn`, `PresetForCategoryFn`, `PresetByNameFn`
- processing/distribution: `ProcessImageFn`, `PersistArtifactFn`,
  `CopyToClipboardFn`, `SaveCaptureActionFn`, `RecognizeTextFn`,
  `PlaySoundFn`, `PostNotificationFn`
- capture/session factories: `HandlePermissionFailureFn`,
  `SelectWindowCaptureFn`, `MakeAreaCaptureSessionFn`,
  `MakeFullscreenCaptureSessionFn`, `MakeWindowCaptureSessionFn`

## Model Property Audit

### `ProcessedScreenshot`

All stored properties have consumers.

- `image`, `cgImage`, `filePath`, `fileName`, and `presetName` are used in UI,
  distribution, and history-sync code
- `context` feeds filename generation and Markdown citation data
- `ocrText` is persisted into history and read by copy/search flows

Removed only dead API around those properties:

- `ProcessedScreenshotImageFormat`
- `encodedImageData(format:)`

### `ScreenshotItem`

Most fields have direct UI/search/persistence consumers. One field stands out:

- `captureMode` appears to be persisted and tested but is not currently read by
  app UI logic

I did not remove `captureMode` in this task because it is part of the on-disk
history schema and removing it would change persisted payloads without a clear
migration benefit. This is an uncertain lifecycle case, not a safe dead-code
removal.

### `CaptureContext`

All properties have consumers:

- `mode` is used by processing, tests, and downstream export logic
- `sourceAppName` / `sourceWindowTitle` are used in filenames, history search,
  UI labels, and Markdown export
- `timestamp` is used by `FileOrganizer` and `MarkdownExporter`

## `KeychainHelper.swift`

`KeychainHelper.swift` cannot be removed.

Current live dependencies:

- `HistoryCrypto.swift` uses `readDataNonInteractive(...)` and `writeData(...)`
  for the active history root key path
- `AppSettings.swift` still uses legacy-read and legacy-delete helpers for
  silent license migration
- `HistoryCryptoTests.swift` still uses `deleteItem(...)`

Conclusion:

- legacy migration is **not** the only remaining use
- removal would break active history encryption key storage
- I updated the file comment to match reality

## `UITestHostWindowController`

Before this task, `UITestHostWindowController.swift` was compiled into all
builds and referenced unconditionally from `CalouraApp.swift`, even though it is
only meant for UI-test hosting.

Action taken:

- wrapped `UITestHostWindowController.swift` in `#if DEBUG`
- changed `CalouraApp.swift` to use a DEBUG-only `isUITestHostEnabled` path

Result:

- UI-test host code is now excluded from production builds
- DEBUG behavior is unchanged for `CALOURA_UI_TEST_HOST=1`

## Summary

Confirmed dead code removed in this task:

1. `AppState.upsertScreenshot(_:)`
2. `AppState.saveHistory()`
3. `CapturePipeline.SaveFileFn`
4. `CapturePipeline.init(... saveFile: ...)`
5. `ProcessedScreenshotImageFormat`
6. `ProcessedScreenshot.encodedImageData(format:)`

Retained but documented:

- `ScreenshotItem.captureMode` as schema-bound / uncertain
- `KeychainHelper.swift` as still live due to `HistoryCrypto` and license migration
