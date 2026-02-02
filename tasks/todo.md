# Plan.md Accuracy Pass + Review Feedback

## Plan

- [x] 1. Collapse changelog to one entry
- [x] 2. Remove .edu claim from product definition (Section A)
- [x] 3. Add explicit non-goals (accessibility, l10n, .edu tier)
- [x] 4a. Fix URL route count: 11 → 10
- [x] 4b. Add test coverage note (9/35 files covered)
- [x] 4c. Fix release.sh line count: 141 → 138
- [x] 4d. Drop commit hash from codebase summary
- [x] 5. Clean up completed items in Section D + add appcast deliverable
- [x] 6. Change CG wording: "deprecated macOS 15" → "legacy — may break in future macOS"
- [x] 7. Update M2 done criteria + add download hosting decision
- [x] 8a. Fix backlog item #5 line count
- [x] 8b. Add dependency note to backlog item #7
- [x] 8c. Clarify hosting in backlog item #8
- [x] 8d. Add backlog item: Appcast + update signing pipeline
- [x] 8e. Add backlog item: macOS 14.x clean-machine validation
- [x] 9a. Expand CG deprecation risk (ContextDetector)
- [x] 9b. Add 3 new risks (EdDSA key loss, bundle version mismatch, notarization brittleness)
- [x] 10. Update open questions (pricing wording, add macOS 14 question)
- [x] 11. Update verified environment
- [x] 12. Add new decisions (binary hosting, .edu deferral)

## Verification

- [x] "141" — zero occurrences in plan.md
- [x] "11 routes" — zero occurrences
- [x] ".edu" — appears only in B (line 28), F/M4 (line 126), G (line 151), K (line 218). NOT in Section A.
- [x] "deprecated macOS 15" — zero occurrences
- [x] All sections A-K present (11 sections confirmed)
- [x] Line count: 218 (above 200 target; net increase from 12 additions is expected)

---

# Previous: Plan.md Review Fixes + M3 Polish + README

## Plan

### Commit 0: Fix plan.md based on review feedback
- [x] Section A — update distribution rationale
- [x] Section D — add items 11 (permissions troubleshooting) and 12 (Sparkle upgrade rehearsal)
- [x] Section H Risk #1 — tone down mitigation
- [x] Section H — add Risk #6 (distribution coupling)
- [x] Section I — add question #6 (history limit / SQLite)
- [x] Section K — update App Store decision rationale
- [x] Section F M2 — add Sparkle upgrade cycle to "Done means"

### Commit 1: Clean up stale root files
- [x] `git rm` HANDOFF.md, HANDOFF-CG-CAPTURE.md, ROADMAP.md
- [x] Remove .build directory and .DS_Store
- [x] Copy CLAUDE.md into repo

### Commit 2: Prevent duplicate pinned screenshot windows
- [x] Add `panelsByKey` dictionary to PinnedScreenshotManager
- [x] Add `dedupKey(for:)` helper (filePath or ObjectIdentifier)
- [x] Guard at top of `pin()` — bring existing to front if duplicate
- [x] Track key on create, clean up on close and unpinAll

### Commit 3: Add Launch at Login preference
- [x] Add `launchAtLogin` key, property, and init to AppSettings
- [x] Add toggle with SMAppService register/unregister in PreferencesView
- [x] Add `syncLaunchAtLoginState()` in CalouraApp (sync on launch)

### Commit 4: Add delayed capture cancellation with countdown overlay
- [x] Add `isCountingDown` and `countdownRemaining` to AppState
- [x] Create CountdownOverlay.swift (NSPanel + SwiftUI, ESC handling)
- [x] Rewrite `captureDelayed()` with Task cancellation + overlay
- [x] Add `cancelDelayedCapture()` method to CapturePipeline
- [x] Add "Cancel Countdown" button to MenuBarView delayed capture menu
- [x] Add `.cancelDelayedCapture` notification and observer in CalouraApp
- [x] Run `xcodegen generate` after adding new file

### Commit 5: Add README.md
- [x] App description + features list
- [x] Keyboard shortcuts table
- [x] Requirements + permissions troubleshooting
- [x] Build instructions
- [x] License placeholder

## Verification
- [x] `xcodegen generate` — project regenerated successfully
- [x] `xcodebuild build` — BUILD SUCCEEDED (no new warnings)
- [x] `xcodebuild test` — all 66 tests pass, 0 failures
- [x] 6 clean commits on main: cfb1cf6, 786fe3a, 1c3109e, 6975221, d03cf78, f83ecfb

## Review / Evidence

- **Build**: BUILD SUCCEEDED — only pre-existing CGWindowListCreateImage deprecation warnings
- **Tests**: All 66 tests pass with 0 failures
- **New file**: `Caloura/UI/CountdownOverlay.swift`
- **Deleted files**: HANDOFF.md, HANDOFF-CG-CAPTURE.md, ROADMAP.md, .build/, .DS_Store
- **Added files**: CLAUDE.md, README.md
- **Modified files**: plan.md, PinnedScreenshotWindow.swift, AppSettings.swift, PreferencesView.swift, CalouraApp.swift, CapturePipeline.swift, MenuBarView.swift, AppState.swift
