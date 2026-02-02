# Lessons Learned

## 2026-02-02: CGWindowList false positive on macOS Sequoia

- **Mistake**: Used `CGWindowListCopyWindowInfo` as a fallback permission signal. It returned named windows from other apps even when screen recording permission was denied on Sequoia.
- **Root cause**: macOS Sequoia changed the behavior of `CGWindowListCopyWindowInfo` — it now returns window metadata (names, owner names) without screen recording permission. This was undocumented.
- **Rule**: Never use `CGWindowListCopyWindowInfo` as a permission check. `CGPreflightScreenCaptureAccess()` is the only reliable OS-level permission signal. SCK's `SCShareableContent` is the authoritative functional check.
- **Example**: `hasAnyPermissionSignal()` returned `true` (from CGWindowList showing 4 named windows) even though both CGPreflight and SCK said no permission. This let capture proceed through CG fallback, which silently produced wallpaper-only screenshots.

## 2026-02-02: NSCursor.hide/unhide imbalance from viewDidMoveToWindow

- **Mistake**: Called `NSCursor.hide()` unconditionally in `viewDidMoveToWindow()`. This method fires both when a view is added to a window (`window != nil`) and removed from one (`window == nil`). The extra hide during removal created an imbalance — more hides than unhides — leaving the cursor permanently hidden.
- **Root cause**: `NSCursor.hide()`/`unhide()` use a reference count. Each hide increments, each unhide decrements. Calling hide on window removal doubled the count, but `removeFromSuperview()` (the only unhide site) was called at most once — and sometimes not at all when `NSWindow.close()` doesn't tear down the view hierarchy.
- **Rule**: Always guard `NSCursor.hide()` behind `window != nil` in `viewDidMoveToWindow()`. Use a boolean flag to ensure each instance's hide/unhide calls are exactly balanced. Provide unhide in both `viewDidMoveToWindow(nil)` and `removeFromSuperview()` as belt-and-suspenders.
- **Example**: After an area capture, the overlay windows were closed via `w.close()`. `viewDidMoveToWindow()` fired again during deallocation with `window == nil`, calling `NSCursor.hide()` a second time. The cursor stayed hidden in all subsequent windows (history, preferences, etc.).
