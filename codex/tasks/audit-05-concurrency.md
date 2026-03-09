# Audit Task 05: Concurrency Safety Audit

## Summary

- Task-start source inventory on `codex/task-05-concurrency`:
  - `@unchecked Sendable`: 12
  - `nonisolated(unsafe)`: 6
  - `@preconcurrency` uses: 7
- Inventory after targeted fixes in this task:
  - `@unchecked Sendable`: 10
  - `nonisolated(unsafe)`: 3
  - `@preconcurrency` uses: 7
- Strict-concurrency probe:
  - `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` passes on this branch
  - ScreenCaptureKit and Sparkle still require `@preconcurrency` on this toolchain

## Targeted Fixes Landed

1. `DefaultScrollDriver` is now internally synchronized with `NSLock`, so its `@unchecked Sendable` claim matches the protocol contract instead of relying on actor-serialized call sites alone.
2. `HistoryView` no longer uses `nonisolated(unsafe)` globals for thumbnail cache state or metrics; both moved into an actor-backed `HistoryThumbnailStore`.
3. `HistoryCrypto` no longer reads and writes DEBUG override state from mixed synchronization domains; override reads/writes now go through the same `keyQueue` that guards the cached key, and key-state helpers now detect re-entry onto that queue to avoid `dispatch_sync` self-deadlocks during tests.
4. `ScrollCaptureOutput` and `ScrollStitchResult` no longer use `@unchecked Sendable`; `CGImage` is Sendable on this toolchain, so both now use plain `Sendable`.

## `@unchecked Sendable` Catalog

| Site | Assessment | Reasoning | Migration outlook |
| --- | --- | --- | --- |
| `Caloura/Models/ProcessedScreenshot.swift:23` | Keep for now | Mutable reference type with lock-protected `filePath`, `fileName`, `presetName`, and cached encodings. The remaining risk is external mutation of referenced `NSImage`, not internal data races. | Medium. Convert to immutable value snapshots or actor-isolated metadata if this model spreads further. |
| `Caloura/Models/EmbeddingStore.swift:21` | Keep for now | Internal `entries` access is serialized by `NSLock`; file I/O uses snapshots outside the lock. | Medium. Actor conversion would remove the escape hatch cleanly. |
| `Caloura/Models/AppState.swift:7` (`UserDefaultsHandle`) | Keep for now | Immutable wrapper used to pass `UserDefaults` into `HistoryPersistenceWorker`. `UserDefaults` is explicitly unavailable-as-Sendable on this toolchain, so the wrapper is the local trust boundary. | Medium. Replace with actor-owned persistence APIs instead of passing handles. |
| `Caloura/Capture/ScrollCaptureHelpers.swift:7` (`BitmapData`) | Keep for now | Wraps an immutable `CFData` owner plus a raw pointer derived from it. Safety depends on pointer lifetime staying tied to `data`, which the struct currently enforces. | Low. Could become plain `Sendable` only if the raw pointer disappears. |
| `Caloura/Capture/ScrollCaptureHelpers.swift:19` (`PreparedFrame`) | Keep for now | Immutable aggregate around `BitmapData`, hashes, and `CGImage`. The unsendable part is still `BitmapData`, not the image. | Low. Falls out automatically if `BitmapData` is redesigned. |
| `Caloura/Capture/ScrollCaptureAXHandles.swift:3` (`AXElementHandle`) | Keep for now | `AXUIElement` is not Sendable on macOS 26.2. The wrapper is immutable and only carries the CF object reference. | Medium. Needs SDK annotations or a stricter actor boundary around accessibility work. |
| `Caloura/Capture/ScrollCaptureAXHandles.swift:20` (`AXValueHandle`) | Keep for now | Same situation as `AXElementHandle`; immutable wrapper around non-Sendable `AXValue`. | Medium. Same blocker as above. |
| `Caloura/Capture/WindowPickerManager.swift:23` (`WindowPickerManager.Result`) | Keep for now | Carries `SCContentFilter`, which is not Sendable on macOS 26.2. `CheckedContinuation` forces a Sendable result boundary here. | High. Best long-term fix is to redesign picker delivery so `SCContentFilter` never crosses a sendable continuation boundary. |
| `Caloura/Capture/ScrollCaptureEngine+Defaults.swift:277` (`DefaultScrollDriver`) | Fixed in this task, keep escape hatch | Before this task, `hasStartedScroll` was unsynchronized mutable state behind a `Sendable` protocol. The new lock makes the unchecked conformance materially true. | Medium. Actor- or serial-executor-backed input synthesis would remove the escape hatch entirely. |
| `Caloura/Capture/ScrollCaptureEngine.swift:316` (`ScrollCaptureEngine.Result`) | Keep for now | `.failed(Error)` carries an unconstrained error existential, so the enum cannot be plain `Sendable` yet. | Medium. Replace with a typed `Sendable` error envelope. |

### Removed `@unchecked Sendable` in this task

| Site | Why it was removable |
| --- | --- |
| `Caloura/Capture/ScrollCaptureEngine.swift:59` (`ScrollCaptureOutput`) | `CGImage` is Sendable on this toolchain, so the wrapper no longer needed an unchecked conformance. |
| `Caloura/Capture/ScrollCaptureEngine.swift:196` (`ScrollStitchResult`) | Same as above: `CGImage` is Sendable, and the remaining fields were already sendable. |

## `nonisolated(unsafe)` Catalog

### Remaining

| Site | Assessment | Reasoning | Migration outlook |
| --- | --- | --- | --- |
| `Caloura/Security/HistoryCrypto.swift:37` (`cachedKey`) | Justified but still a blocker | All reads/writes now occur under `keyQueue.sync`, so I did not find a live race after this task. Swift still requires an escape hatch because it cannot verify the external lock discipline. | High. Replace queue-protected globals with an actor or dedicated serial executor. |
| `Caloura/Security/HistoryCrypto.swift:39` (`securityDirectoryOverride`) | Fixed read/write race, still a blocker | This task moved both reads and writes onto `keyQueue`, eliminating the previous mixed-synchronization access pattern. The escape hatch remains because the compiler cannot prove that discipline. | High. Same actor/executor migration as above. |
| `Caloura/Security/HistoryCrypto.swift:40` (`keychainItemOverride`) | Fixed read/write race, still a blocker | Same as `securityDirectoryOverride`; now queue-serialized, but still externally synchronized mutable global state. | High. Same actor/executor migration as above. |

### Removed in this task

| Former site | Resolution |
| --- | --- |
| `Caloura/UI/HistoryView.swift:5` (`HistoryThumbnailCache.shared`) | Replaced with actor-backed `HistoryThumbnailStore.shared`. |
| `Caloura/UI/HistoryView.swift:17` (`HistoryThumbnailMetrics.requests`) | Folded into `HistoryThumbnailStore` actor state. |
| `Caloura/UI/HistoryView.swift:18` (`HistoryThumbnailMetrics.hits`) | Folded into `HistoryThumbnailStore` actor state. |

## `@preconcurrency` Catalog

| Site | Assessment | Evidence | Migration outlook |
| --- | --- | --- | --- |
| `Caloura/App/UpdateManager.swift:2` | Required | Probe: `swiftc -F ...Sparkle.framework -strict-concurrency=complete -warn-concurrency -typecheck /tmp/check_sparkle_sendable.swift` reports Sparkle types as non-Sendable and explicitly suggests `@preconcurrency import Sparkle`. | High blocker until Sparkle ships concurrency annotations. |
| `Caloura/App/UpdateManager+Sparkle.swift:2` | Required | Same Sparkle probe as above. `SPUStandardUpdaterController`, `SPUUpdater`, and `SUAppcastItem` are still non-Sendable on this toolchain. | High blocker. |
| `Caloura/Capture/WindowPickerManager.swift:2` | Required | Probe: `swiftc -strict-concurrency=complete -warn-concurrency -typecheck /tmp/check_sck_sendable.swift` reports `SCContentFilter`, `SCContentSharingPicker`, and `SCShareableContent` as non-Sendable and explicitly suggests `@preconcurrency import ScreenCaptureKit`. | High blocker until ScreenCaptureKit annotations improve. |
| `Caloura/Capture/WindowPickerManager.swift:97` (`@preconcurrency SCContentSharingPickerObserver`) | Required | The observer callbacks are Objective-C delegate entry points from ScreenCaptureKit. The conformance still bridges through non-Sendable SDK types. | High blocker. |
| `Caloura/Capture/WindowPickerManager+SystemPicker.swift:1` | Required | Same ScreenCaptureKit probe as above. | High blocker. |
| `Caloura/Capture/ScreenCaptureManager.swift:1` (`AppKit`) | Required | Probe: `swiftc -strict-concurrency=complete -warn-concurrency -typecheck /tmp/check_appkit_sendable_strict.swift` reports `NSScreen` as explicitly unavailable-as-Sendable on macOS 26.2. | Medium blocker until AppKit annotations improve or `NSScreen` stops crossing sendable boundaries. |
| `Caloura/Capture/ScreenCaptureManager.swift:3` (`ScreenCaptureKit`) | Required | Same ScreenCaptureKit probe as above. | High blocker. |

## Candidate Race Review

### `ScreenCaptureManager.sckFailed`

- Status: no live race found
- Reasoning:
  - `ScreenCaptureManager` is `@MainActor`
  - every read/write of `sckFailed`, `sckFailureCount`, `cachedContent`, and `cachedContentTimestamp` occurs in `@MainActor` instance methods
  - detached helpers in `ScreenCaptureManager+CLICapture.swift` and `ScreenCaptureManager+PermissionTools.swift` do not touch those properties
  - notification callbacks re-enter through `Task { @MainActor ... }`
- Conclusion: this is a Swift-6 migration review item, not a current race bug

### `CapturePipeline` mutable state (`overlayWindows`, `screenOverlays`, sessions, tasks, counters)

- Status: no live race found
- Reasoning:
  - `CapturePipeline` is `@MainActor`
  - all mutations happen from main-actor methods or explicit `Task { @MainActor ... }` re-entry
  - the one inherited task (`delayedCaptureTask`) is created from a `@MainActor` method and does not detach work that mutates pipeline state off actor
- Conclusion: the current mutable state is actor-isolated. The main debt here is architectural size and visibility, not an active data race.

### `HistoryCrypto` override state

- Status: real race risk existed, fixed in this task
- Prior problem:
  - DEBUG setters wrote `securityDirectoryOverride` / `keychainItemOverride` directly
  - reads happened through code paths synchronized by `keyQueue`
  - that mixed access discipline meant strict external serialization was not actually true
- Fix:
  - reads and writes now go through `keyQueue`
  - queue-backed helpers now bypass `dispatch_sync` when already executing on `keyQueue`, which resolved the package-test `signal code 5` crash caused by nested queue access during key creation

### `DefaultScrollDriver.hasStartedScroll`

- Status: real sendability mismatch existed, fixed in this task
- Prior problem:
  - `ScrollDriving` requires `Sendable`
  - `DefaultScrollDriver` claimed `@unchecked Sendable`
  - `hasStartedScroll` was plain mutable state with no synchronization
- Fix:
  - added `NSLock` around all reads/writes of `hasStartedScroll`

### History thumbnail cache globals

- Status: unnecessary unsafe global state existed, fixed in this task
- Prior problem:
  - cache and metrics lived in `nonisolated(unsafe)` globals
  - cache writes happened from detached thumbnail-loading work
- Fix:
  - replaced the globals with actor-backed `HistoryThumbnailStore`

## Swift 6 Migration Blockers

1. ScreenCaptureKit is still not concurrency-annotated enough on macOS 26.2.
   - Concrete blockers observed: `SCContentFilter`, `SCContentSharingPicker`, `SCShareableContent`, `SCDisplay`, `SCRunningApplication`
2. Sparkle still requires `@preconcurrency`.
   - Concrete blockers observed: `SPUStandardUpdaterController`, `SPUUpdater`, `SUAppcastItem`
3. AppKit still has non-Sendable edges.
   - Concrete blocker observed: `NSScreen` is explicitly unavailable-as-Sendable
4. Accessibility CF wrappers still need unchecked or isolated boundaries.
   - Concrete blockers observed: `AXUIElement`, `AXValue`
5. `HistoryCrypto` still relies on externally synchronized mutable globals.
   - Safe after this task’s queue fix, but still a compiler-visible migration blocker
6. `ScrollCaptureEngine.Result` still carries an unconstrained `Error`.
   - This keeps one unchecked sendability hole alive in a core async result path
7. Mutable class models still rely on lock discipline instead of actor/value semantics.
   - `ProcessedScreenshot`, `EmbeddingStore`

## Recommended Follow-Up Order

1. Replace `ScrollCaptureEngine.Result.failed(Error)` with a typed `Sendable` error envelope.
2. Actor-ize `HistoryCrypto` key state so the three remaining `nonisolated(unsafe)` globals disappear.
3. Redesign `WindowPickerManager` so `SCContentFilter` stays on the main actor and never crosses a sendable continuation boundary.
4. Convert `EmbeddingStore` to an actor.
5. Decide whether `ProcessedScreenshot` should stay a reference type or become an immutable snapshot plus sidecar metadata.

## Validation

- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`
- `swift build`
- `swiftlint`
- `swift test`

### Validation result

- All four commands pass on `codex/task-05-concurrency`
- `swift test` result: 465 tests passed, 0 failures
