# Task 10: Performance & Memory Audit

## Summary

- Overall severity: no Critical or High findings
- Medium findings: startup main-thread blocking, long-scroll capture working-set growth
- Low findings: thumbnail cache sizing, embedding search scaling, history scaling beyond the current 50-item cap
- Targeted fixes applied:
  - Cached `NLEmbedding` instances in `EmbeddingEngine` to avoid repeated model lookup on every search/enrichment call
  - Replaced full-result sorting in `EmbeddingStore.findSimilar(...)` with bounded top-K insertion
  - Moved semantic search execution off the main actor and wrapped thumbnail decoding in an autorelease pool
  - Removed the extra full-canvas copy during scroll stitching and wrapped scroll-frame preparation in autorelease pools

## Findings

### 1. Image buffer lifecycle in ScrollCapture

- Rating: Medium
- Evidence:
  - `ScrollCaptureHelpers.PreparedFrame` retains the original `CGImage`, an RGBA bitmap, a grayscale buffer, and row hashes for every accepted frame: `Caloura/Capture/ScrollCaptureHelpers.swift:19-27`
  - Bitmap preparation still materializes an RGB context and then extracts provider-backed pixel data: `Caloura/Capture/ScrollCaptureHelpers+Preparation.swift:5-34`
  - Automatic settling retains up to six prepared probes per step before unstable-band analysis: `Caloura/Capture/ScrollCaptureEngine+Defaults.swift:357-399`
- Fixes applied:
  - `ScrollCaptureEngine.prepareCapturedFrame(...)` now wraps `prepareFrame(...)` in `autoreleasepool`: `Caloura/Capture/ScrollCaptureEngine+Capture.swift:363-370`
  - `DefaultScrollSettling.settle(...)` now does the same for each probe: `Caloura/Capture/ScrollCaptureEngine+Defaults.swift:360-367`
  - `ScrollCaptureHelpers.stitch(...)` now transfers the stitched RGBA canvas directly into `CGDataProvider` ownership instead of cloning it into a second `Data` buffer: `Caloura/Capture/ScrollCaptureHelpers+Stitching.swift:19-80`, `Caloura/Capture/ScrollCaptureHelpers+Stitching.swift:168-199`
- Assessment:
  - The fix removes the largest avoidable temporary allocation in the final stitch path.
  - The remaining ceiling is accepted-frame retention. That is structural, not incidental.

### 2. History scaling with 1,000+ screenshots

- Rating: Low
- Evidence:
  - `AppState` caps in-memory history at 50 items via `maxRecentItems`: `Caloura/Models/AppState.swift:69-71`
  - `HistoryView` renders the entire filtered result set in one `LazyVGrid`, with no paging/windowing beyond SwiftUI laziness: `Caloura/UI/HistoryView.swift:60-148`
  - `HistorySearchModel` performs an O(n) substring scan across all text fields: `Caloura/UI/HistorySearchModel.swift:7-37`
- Assessment:
  - The current product does not actually carry 1,000 items in memory, so UI performance is bounded today.
  - The real issue is capability: if Caloura later keeps full history instead of a 50-item recent list, it will need paged persistence-backed loading rather than simply raising `maxRecentItems`.
- Recommendation:
  - Keep `recentScreenshots` as a small hot set and introduce a paged history source for older captures instead of turning the current array into a long-term archive.

### 3. ThumbnailCache size limits and eviction

- Rating: Low
- Evidence:
  - `HistoryThumbnailStore` uses `NSCache` with `countLimit = 200` and `totalCostLimit = 50 MB`: `Caloura/UI/HistoryView.swift:4-35`
  - Thumbnail decoding previously happened off-main, but without an autorelease pool and with eager cache creation for every miss: `Caloura/UI/HistoryView.swift:389-421`
- Fixes applied:
  - Thumbnail generation now runs in a utility-priority detached task and is wrapped in `autoreleasepool`: `Caloura/UI/HistoryView.swift:395-421`
- Assessment:
  - Current cache limits are acceptable for the existing 50-item history cap.
  - The cache is not the bottleneck today; it already has explicit cost limits and eviction semantics.
- Recommendation:
  - If full-history pagination is added later, keep the cache but tune limits from actual thumbnail dimensions and hit-rate telemetry.

### 4. EmbeddingStore search complexity

- Rating: Medium
- Evidence:
  - Search still scans every stored embedding linearly: `Caloura/Models/EmbeddingStore.swift:56-79`
  - Semantic queries originate from `HistoryView` and are used as fallback search when substring matching fails: `Caloura/UI/HistoryView.swift:182-198`, `Caloura/UI/HistorySearchModel.swift:7-25`
- Fixes applied:
  - Cached `NLEmbedding` instances in `EmbeddingEngine`: `Caloura/Processing/EmbeddingEngine.swift:4-23`
  - Replaced full-array sort in `EmbeddingStore.findSimilar(...)` with bounded top-K insertion: `Caloura/Models/EmbeddingStore.swift:56-79`
  - Added regression coverage for top-K ordering: `CalouraTests/ProcessingTests/EmbeddingStoreTests.swift:67-81`
- Assessment:
  - This removes repeated model lookup and avoids sorting the full candidate set when only the best few matches are needed.
  - Complexity is still O(n) over the stored embeddings, which is acceptable at current scale but will not stay cheap if Caloura evolves into a long-lived semantic archive.
- Recommendation:
  - If semantic history grows beyond low-thousands of entries, move to a pre-normalized matrix or ANN-style index instead of continuing to scan the whole store.

### 5. Debounce effectiveness under rapid changes

- Rating: Low
- Evidence:
  - History persistence already debounces writes at 500 ms and persists off the main actor: `Caloura/Models/AppState.swift:231-273`
  - Semantic search debounced for 300 ms, but the actual embedding search previously ran from the UI task context: `Caloura/UI/HistoryView.swift:182-198`
- Fixes applied:
  - Semantic search now performs the heavy `EmbeddingEngine.search(...)` call in a detached utility task and only publishes results back on the main actor: `Caloura/UI/HistoryView.swift:187-197`
- Assessment:
  - The debounce policy was already reasonable; the problem was actor placement, not interval choice.

### 6. Startup main-thread blocking

- Rating: Medium
- Evidence:
  - `AppState` is `@MainActor`, and its initializer synchronously calls `loadHistory()`, `embeddingStore.load()`, and the permission audit: `Caloura/Models/AppState.swift:45-97`
  - `loadHistory()` performs file I/O, decryption, JSON decode, and partial-recovery fallback synchronously during initialization: `Caloura/Models/AppState.swift:293-369`
  - `embeddingStore.load()` also performs file I/O, decryption, and JSON decode synchronously: `Caloura/Models/EmbeddingStore.swift:100-127`
- Assessment:
  - Cold launch cost scales directly with encrypted history size and embedding payload size.
  - I did not change hydration timing in this task because the current initialization contract is test-visible and product-visible.
- Recommendation:
  - Split startup state into “required for launch” and “hydrate after launch” buckets. History metadata and embeddings should move behind a background hydration phase with an explicit ready signal.

### 7. ScrollCapture memory ceiling during 20,000 px capture

- Rating: Medium
- Evidence:
  - A 1,440 px wide, 20,000 px tall RGBA stitch canvas is roughly `1440 * 20000 * 4` bytes, or about 110 MB, before frame metadata.
  - Before this task, the stitcher allocated that canvas and then copied it again into `Data` when creating the final `CGImage`.
  - `PreparedFrame` also retains extra grayscale and row-hash buffers per accepted frame: `Caloura/Capture/ScrollCaptureHelpers.swift:19-27`, `Caloura/Capture/ScrollCaptureHelpers+Preparation.swift:37-52`
- Fixes applied:
  - Removed the duplicate stitched-canvas copy: `Caloura/Capture/ScrollCaptureHelpers+Stitching.swift:168-199`
- Assessment:
  - Peak memory is materially better now, but long captures can still climb because accepted frames are retained until the final stitch completes.
- Recommendation:
  - The next step is incremental stitching or tiled spill-to-disk once scroll capture is stable enough to avoid needing the full accepted-frame set in memory.

## Targeted Fixes Completed

- `Caloura/Processing/EmbeddingEngine.swift`
  - Cached sentence and word embeddings
- `Caloura/Models/EmbeddingStore.swift`
  - Bounded top-K search to avoid full-result sort
- `Caloura/UI/HistoryView.swift`
  - Moved semantic search work off the main actor
  - Wrapped thumbnail creation in `autoreleasepool`
- `Caloura/Capture/ScrollCaptureEngine+Capture.swift`
  - Wrapped prepared-frame creation in `autoreleasepool`
- `Caloura/Capture/ScrollCaptureEngine+Defaults.swift`
  - Wrapped probe preparation in `autoreleasepool`
- `Caloura/Capture/ScrollCaptureHelpers+Stitching.swift`
  - Eliminated the extra stitched-canvas copy

## Recommended Follow-Ups

1. Move encrypted history and embedding hydration off the launch-critical main-actor path.
2. If product requirements expand beyond the current 50-item recent history, introduce paged history storage instead of increasing the in-memory cap.
3. Rework scroll capture to stitch incrementally or spill old frame buffers once accepted.
