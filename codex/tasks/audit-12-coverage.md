# Task 12: Test Coverage Gaps

## Summary

Task 12 closed the highest-value unit-test gaps called out in the audit plan:

- Added 5 focused `CaptureEnrichmentCoordinator` tests covering FIFO ordering,
  concurrency limits, duplicate deduplication, cancellation, and pending-work
  scheduling.
- Added `CaptureDistributionService` regression coverage for the known
  double-enrichment risk on save.
- Added `AppCommandController` routing tests by introducing a narrow injected
  routing seam instead of relying on `CapturePipeline.shared` in tests.

## Tests Added

### `CaptureEnrichmentCoordinatorTests`

New coverage in
`CalouraTests/AppTests/CaptureEnrichmentCoordinatorTests.swift`:

1. `testEnqueue_preservesFIFOOrderWhenLimitedToOneWorker`
2. `testEnqueue_limitsConcurrentJobs`
3. `testEnqueue_replacesPendingOperationForDuplicateScreenshotID`
4. `testCancelAll_cancelsRunningWorkAndDropsPendingOperations`
5. `testFinish_startsNextPendingOperationWhenASlotOpens`

These tests cover the coordinator's externally observable contract without
reaching into actor internals.

### `CaptureDistributionServiceTests`

New coverage in
`CalouraTests/AppTests/CaptureDistributionServiceTests.swift`:

1. `testPerformQuickActionSave_skipsEnrichmentWhenPreviewAlreadyPending`
2. `testSaveLastCapture_skipsEnrichmentWhenScreenshotAlreadyHasOCRText`

This closes the specific "double enrichment on manual save" regression risk by
verifying that save paths do not enqueue enrichment when the preview is already
pending or OCR data already exists.

### `AppCommandControllerTests`

New coverage in
`CalouraTests/AppTests/AppCommandControllerTests.swift`:

1. `testHandle_captureCommandsRouteToPipelineMethods`
2. `testHandle_captureScrollShowsTipBeforeRouting`
3. `testHandle_distributionCommandsRouteToPipelineMethods`

These tests verify command routing behavior without needing to exercise
singleton-heavy UI side effects.

## Existing Coverage Confirmed

The audit plan asked for `CapturePipeline.performCapture` error-path coverage
for `CaptureError.noPermission` and generic errors. That coverage already
existed before this task in
`CalouraTests/AppTests/CapturePipelineTests.swift`:

- `testPerformCapture_permissionError`
- `testPerformCapture_genericError`

I did not duplicate those tests in this task.

## Coverage Still Better Suited Elsewhere

The following paths remain better suited to system/UI testing than new unit
tests in this task:

- `AppCommandController` window-presentation flows like permission repair,
  history, settings, annotation, beautify, and redact, because they depend on
  AppKit controllers and global singleton presentation state.
- `CaptureDistributionService` clipboard and save failure presentation details,
  which are already low-risk injected paths and were not the known regression
  target for this task.
- End-to-end enrichment execution after enqueue, which is already covered more
  meaningfully through pipeline and app-state integration tests than by
  duplicating coordinator internals.
