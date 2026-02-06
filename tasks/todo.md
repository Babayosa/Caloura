# Task 17 — Make CapturePipeline Testable via Closure-Based DI

Date: 2026-02-06
Owner: Caloura Engineering
Status: Complete

## Plan Checklist

### Worker A: Refactor CapturePipeline.swift
- [x] A1. Add 11 typealiases for closure signatures
- [x] A2. Replace hardcoded singleton properties with injectable closures
- [x] A3. Add dual init (private production + internal testing)
- [x] A4. Update `performCapture` body to use injected closures
- [x] A5. Update `processCapture` body to use injected closures
- [x] A6. Update `distributeCapture` body to use injected closures
- [x] A7. Update `addToHistoryWithOCR` body — fix `AppState.shared` bug on line 200

### Worker B: Write Tests
- [x] B1. Create `CapturePipelineTestHelpers.swift` with `makePipeline()` factory
- [x] B2. Create `CapturePipelineTests.swift` with 15 test cases

### Manager: Verification Gate
- [x] C1. `swift build` — clean
- [x] C2. `swift test` — 224 tests, 0 failures
- [x] C3. `swiftlint lint --quiet` — zero warnings
- [x] C4. Verify EntryPoints + Distribution files untouched
- [x] C5. Update tasks/lessons.md

## Verification / Evidence

```
$ swift build
Build complete! (0.20s)

$ swift test
Executed 224 tests, with 0 failures (0 unexpected) in 4.212 (4.231) seconds

$ swiftlint lint --quiet
(no output — clean)

$ git status --short
 M Caloura/App/CapturePipeline.swift
 M tasks/todo.md
?? CalouraTests/AppTests/CapturePipelineTests.swift
?? CalouraTests/Helpers/CapturePipelineTestHelpers.swift
```

**Files changed:** Only `CapturePipeline.swift` modified (refactored). EntryPoints and Distribution untouched.
**New files:** `CapturePipelineTests.swift` (15 tests), `CapturePipelineTestHelpers.swift` (test factory).
**Bug fixed:** `addToHistoryWithOCR` no longer hardcodes `AppState.shared` — uses captured `self.appState` for testability and correctness.

---

# Task 16 — Implement Deferred Audit Fixes

Date: 2026-02-06
Owner: Caloura Engineering
Status: Complete

## Fixes Implemented

- [x] Fix 6 (P1): Surface file save errors to user (`CapturePipeline.swift:141`)
  - Added `appState.statusMessage = "Save failed: \(desc)"` in catch block
- [x] Fix 7 (P1): Add `totalCostLimit` to thumbnail cache (`HistoryView.swift:7-8,387`)
  - Set `cache.totalCostLimit = 50 * 1024 * 1024` (50 MB)
  - Pass `cost: cgThumb.width * cgThumb.height * 4` to `setObject`
- [x] Fix 8 (P2): Cap undo/redo stacks at 30 levels (`AnnotationOverlay.swift:139`)
  - Added `if undoStack.count >= 30 { undoStack.removeFirst() }` before append
- [x] Fix 9 (ADV): Clear `lastScreenshot` after 5 min idle (`AppState.swift`)
  - Added `lastScreenshotTimer: Timer?` stored property
  - Added `didSet` on `lastScreenshot` that schedules 5-min timer to nil it
  - Timer uses `[weak self]` to avoid retain cycles
- [x] Fix 10 (ADV): Downscale pinned image to window size (`PinnedScreenshotWindow.swift`)
  - When `scale < 1.0`, draws full image into new `NSImage` at `windowSize`
  - Uses `lockFocus`/`draw`/`unlockFocus` pattern
  - Downscaled image passed to both `PinnedScreenshotView` and `onCopy` closure

## Verification

- [x] `swift build` — clean (2.70s)
- [x] `swift test` — 209 tests, 0 failures (4.23s)
- [x] `swiftlint lint --quiet` — zero warnings

```
$ swift build
Build complete! (2.70s)

$ swift test
Executed 209 tests, with 0 failures (0 unexpected) in 4.208 (4.228) seconds

$ swiftlint lint --quiet
(no output — clean)
```

## Remaining Deferred Items

| # | Sev | Finding | Reason |
|---|-----|---------|--------|
| 5 | P1 | Commit `publish.sh` and `release.sh` changes | Script commit, not code fix |
| 11 | ADV | CapturePipeline zero test coverage | Requires protocol injection refactor |

---

# Task 15 — Comprehensive Stability & Optimization Audit

Date: 2026-02-06
Owner: Caloura Engineering
Status: Complete

## Phase 1: Parallel Audit (7 streams)

- [x] Stream 1: Concurrency Safety audit
- [x] Stream 2: Memory & Performance audit
- [x] Stream 3: Error Handling & Resilience audit
- [x] Stream 4: Security Hardening audit
- [x] Stream 5: Test Coverage Gaps audit
- [x] Stream 6: Build & Release Pipeline audit
- [x] Stream 7: Dead Code & Hygiene audit

## Phase 2: Triage & Consolidate

- [x] Merge all findings into prioritized list
- [x] Deduplicate cross-stream findings
- [x] Group into implementation tasks

## Phase 3: Fix Implementation

### P0 Fixes (data loss, crashes)
- [x] Add `applicationWillTerminate` to flush pending saves (`CalouraApp.swift`)
  - Changed `AppState.saveHistoryNow()` from private to internal
  - Changed `AppSettings.saveAllSettings()` from private to internal
  - Added `applicationWillTerminate` handler calling both
- [x] Guard empty `filePath` in HistoryView open/reveal/copy actions (`HistoryView.swift`)

### P1 Fixes (error handling gaps)
- [x] Guard `pngData`/`tiffData` — don't cache `Data()` on encoding failure (`ProcessedScreenshot.swift`)
  - Failure now returns `Data()` without caching, allowing retry on next access
- [ ] Commit uncommitted scripts (deferred — not in scope of code fixes)

### P2 Fixes (dead code, documentation)
- [x] Fix QuickAccessOverlay docstring: "5 seconds" → "3 seconds" (`QuickAccessOverlay.swift`)
- [x] Redundant Foundation imports — skipped (harmless, low value)

### New Tests
- [ ] ProcessedScreenshot encoding failure tests (deferred — requires mock ImageProcessor)
- [ ] CapturePipeline tests (deferred — requires protocol injection refactor)

## Phase 4: Verification

- [x] `swift build` — clean (3.37s)
- [x] `swift test` — 209 tests, 0 failures (4.29s)
- [x] `swiftlint lint --quiet` — zero warnings
- [x] Update evidence section
- [x] Update `tasks/lessons.md` with discoveries

## Verification / Evidence

```
$ swift build
Build complete! (3.37s)

$ swift test
Executed 209 tests, with 0 failures (0 unexpected) in 4.291 (4.308) seconds

$ swiftlint lint --quiet
(no output — clean)
```

## Consolidated Audit Findings (for future reference)

### Implemented (Task 15)
| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | P0 | No `applicationWillTerminate` — debounced saves lost on quit | Added handler flushing both AppState + AppSettings |
| 2 | P0 | `openInPreview`/`openInFinder`/`copyImage` no guard on empty filePath | Added `guard !item.filePath.isEmpty` |
| 3 | P1 | `pngData`/`tiffData` cache `Data()` on failure — 0-byte files | Don't cache on failure, allow retry |
| 4 | P2 | QuickAccessOverlay comment says "5 seconds", timer is 3.0 | Fixed comment |

### Implemented (Task 16)
| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 6 | P1 | File save errors silent to user | `appState.statusMessage = "Save failed: ..."` |
| 7 | P1 | Thumbnail cache no memory limit | `totalCostLimit = 50 MB`, pass cost per entry |
| 8 | P2 | Undo/redo stacks unbounded | Cap at 30, `removeFirst()` on overflow |
| 9 | ADV | `lastScreenshot` holds CGImage forever | 5-min timer clears to nil |
| 10 | ADV | Pinned window holds full-res image | Downscale to window size on pin |

### Remaining Deferred
| # | Sev | Finding | Reason |
|---|-----|---------|--------|
| 5 | P1 | Commit `publish.sh` and `release.sh` changes | Script commit, not code fix |
| 11 | ADV | CapturePipeline zero test coverage | Requires protocol injection refactor |
