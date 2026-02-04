# Performance Optimization — Complete ✅

## Round 1: Critical Path Fixes

| Fix | Before | After |
|-----|--------|-------|
| ContextDetector | 100-500ms (CGWindowList) | <1ms (O(1) lookup) |
| SmartCropper | 100-500ms (blocking Vision) | async + 300ms timeout |
| FileOrganizer | 100-1000ms (blocking I/O) | async background I/O |
| OCREngine | 500ms-5s (.accurate) | 50-200ms (.fast) |
| WindowPicker | 50-200ms (SCShareable query) | 0ms (direct filter) |

## Round 2: Additional Optimizations

| Fix | Issue | Solution |
|-----|-------|----------|
| ProcessedScreenshot | TIFF re-encoded on every copy | Lazy-cached tiffData property |
| ClipboardManager | Called ImageProcessor.tiffRepresentation() each time | Uses cached screenshot.tiffData |
| AppState.saveHistory() | Synchronous I/O on main thread | Debounced (500ms) + background thread |
| ScreenCaptureManager | Duplicate app icon lookups | NSCache for bundle ID → icon |

## Cleanup
- [x] Deleted `WindowSelectionView.swift` (~300 lines)
- [x] Deleted `WindowSelectionOverlayWindow.swift` (~80 lines)

---

## Distribution — Complete ✅

- [x] Create Gumroad product page
- [x] Replace placeholder product ID
- [x] Deploy landing page
- [x] Set real price
- [x] Wire download link
- [x] Capture app screenshots

---

## Low-Priority (Optional)

- [ ] History view NSImage thumbnail caching
- [ ] Batch NSPasteboard writes with writeObjects()
- [ ] Pre-encode TIFF during ImageProcessor.process() instead of lazy
