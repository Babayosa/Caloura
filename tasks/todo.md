# Task 21 — Code Review Fixes (18 Issues)

Date: 2026-02-17
Owner: Caloura Engineering
Status: Complete

## Phase 1: Critical Fixes (Issues 2, 9)

- [x] Issue 2: Create `Timeout.swift` shared `withTimeout` utility
- [x] Issue 2: Refactor `SmartMetadataGenerator` to use `withTimeout` (was broken `withThrowingTaskGroup` race)
- [x] Issue 2: Refactor `SmartCropper` to use `withTimeout` (DRY with shared utility)
- [x] Issue 9: `saveRedactedImage` returns `Bool` for error propagation
- [x] Issue 9: `commitAndClose` checks save result, shows error, stays open on failure
- [x] Build + test gate ✓

## Phase 2: Core Bugs (Issues 5, 6, 7)

- [x] Issue 5: `EmbeddingEngine` splits on `\.isWhitespace` instead of just `" "`
- [x] Issue 6: Annotation handler updates `AppState.shared.lastScreenshot` after disk save
- [x] Issue 7: `SingleWindowPresenter` cleans up stale observer before creating new window
- [x] Issue 7: Observer uses local `observerToken` capture, runs synchronously on `.main` queue
- [x] Build + test gate ✓

## Phase 3: Persistence & Security (Issues 1, 4, 10, 11, 12)

- [x] Issue 1: Add `writeEncrypted`/`readEncrypted`/`applicationSupportURL` to `HistoryCrypto`
- [x] Issue 1: Refactor `AppState.saveHistoryNow()` to use `HistoryCrypto.writeEncrypted`
- [x] Issue 1: Refactor `EmbeddingStore.save()` to use `HistoryCrypto.writeEncrypted`
- [x] Issue 1: Refactor `EmbeddingStore.defaultStoreURL()` / `AppState.defaultHistoryFileURL()` to use `applicationSupportURL`
- [x] Issue 4: Add `saveHistorySync()` — synchronous flush for termination path
- [x] Issue 4: `applicationWillTerminate` calls `saveHistorySync()` instead of `saveHistoryNow()`
- [x] Issue 10: `FileOrganizer.save()` writes atomically + sets 0o600 permissions
- [x] Issue 11: Atomic key creation with POSIX `O_CREAT | O_EXCL` (prevents TOCTOU race)
- [x] Issue 12: `htmlImageTag` percent-encodes filename in `src` attribute
- [x] Build + test gate ✓

## Phase 4: DRY & Polish (Issues 3, 8, 17, 18)

- [x] Issue 3: Arrow shape split into stroked shaft + filled `ArrowHeadShape` triangle
- [x] Issue 8: Add `ClipboardManager.copyNSImage()` method
- [x] Issue 8: Route `PinnedScreenshotWindow`, `BeautifyPreviewOverlay`, `RedactionReviewOverlay`, `HistoryView` through `ClipboardManager.copyNSImage`
- [x] Issue 17: Static `CIContext` in `RedactionEngine` (avoids per-call allocation)
- [x] Issue 18: Combine two `MainActor.run` blocks in `CapturePipeline.generateSmartMetadata`
- [x] Build + test gate ✓

## Phase 5: Test Improvements (Issues 13, 14, 15, 16)

- [x] Issue 13: Add `URLSchemeHandler.parse()` returning `ParsedAction` enum, rewrite tests with assertions
- [x] Issue 14: Create shared `pollUntil` async helper, replace 5 `Task.sleep` waits in license tests
- [x] Issue 15: Add `ClipboardManager.pasteboardOverride` (`#if DEBUG`), tests use named pasteboard
- [x] Issue 16: Add `ProcessedScreenshotTests` (title fallback, PNG/TIFF data, caching, dimensions)
- [x] Issue 16: Add `RedactionEngine` edge cases (overlapping, out-of-bounds, tiny, full-image, many regions)
- [x] Build + test gate ✓

## Review / Evidence

- **Build**: `xcodebuild build` — BUILD SUCCEEDED
- **Tests**: `swift test` — 313 tests, 0 failures
- **Lint**: `swiftlint lint --quiet` — 0 new warnings (pre-existing only)

### Files Modified (25 total, 3 new)

| File | Issues |
|------|--------|
| **NEW** `Caloura/Processing/Timeout.swift` | 2 |
| `Caloura/Processing/SmartMetadataGenerator.swift` | 2 |
| `Caloura/Processing/SmartCropper.swift` | 2 |
| `Caloura/UI/RedactionReviewOverlay.swift` | 9, 8 |
| `Caloura/Processing/EmbeddingEngine.swift` | 5 |
| `Caloura/App/CalouraApp.swift` | 6, 4 |
| `Caloura/UI/SingleWindowPresenter.swift` | 7 |
| `Caloura/Security/HistoryCrypto.swift` | 1, 11 |
| `Caloura/Models/AppState.swift` | 1, 4 |
| `Caloura/Models/EmbeddingStore.swift` | 1 |
| `Caloura/Distribution/FileOrganizer.swift` | 10 |
| `Caloura/Distribution/MarkdownExporter.swift` | 12 |
| `Caloura/Distribution/ClipboardManager.swift` | 8, 15 |
| `Caloura/UI/AnnotationOverlay.swift` | 3 |
| `Caloura/UI/PinnedScreenshotWindow.swift` | 8 |
| `Caloura/UI/BeautifyPreviewOverlay.swift` | 8 |
| `Caloura/UI/HistoryView.swift` | 8 |
| `Caloura/Processing/RedactionEngine.swift` | 17 |
| `Caloura/App/CapturePipeline.swift` | 18 |
| `Caloura/App/URLSchemeHandler.swift` | 13 |
| `CalouraTests/AppTests/URLSchemeHandlerTests.swift` | 13 |
| `CalouraTests/AppTests/LicenseManagerNetworkTests.swift` | 14 |
| `CalouraTests/DistributionTests/ClipboardManagerTests.swift` | 15 |
| **NEW** `CalouraTests/ProcessingTests/ProcessedScreenshotTests.swift` | 16 |
| `CalouraTests/ProcessingTests/RedactionEngineTests.swift` | 16 |
| **NEW** `CalouraTests/Helpers/AsyncTestHelpers.swift` | 14 |
