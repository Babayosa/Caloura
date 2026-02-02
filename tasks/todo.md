# Menu Bar Redesign: Emulate Shottr Layout

## Plan

- [x] 1. Change `.menuBarExtraStyle(.window)` → `.menuBarExtraStyle(.menu)` in CalouraApp.swift
- [x] 2. Rewrite MenuBarView.swift body for native menu layout:
  - Remove `VStack`/`Section` wrappers (not needed for `.menu` style)
  - Remove inline shortcut text `(⌃⇧4)` etc from labels
  - Promote OCR to top-level (disabled when no capture)
  - Add "More" submenu containing: Repeat, Delayed, post-capture actions, Preset
  - Restructure bottom: History → divider → Preferences/Updates/Quit
  - Remove Setup Guide from top-level menu
- [x] 3. `xcodebuild build` — clean compile
- [x] 4. `xcodebuild test` — all 66 tests pass
- [x] 5. Add verification evidence

## Verification

- **Build**: BUILD SUCCEEDED — no new warnings (only pre-existing CGWindowListCreateImage deprecation)
- **Tests**: 66 tests executed, 0 failures — TEST SUCCEEDED
- **Files changed**: `Caloura/App/CalouraApp.swift` (line 15), `Caloura/UI/MenuBarView.swift` (full body rewrite)
- **No notification names changed** — all CalouraApp.swift handlers untouched
- **Notification extension kept intact** — `.showSetupGuide` still declared (used by onboarding), just removed from top-level menu

### Menu structure (new)
```
Capture Area              ⌃⇧4
Capture Window            ⌃⇧5
Capture Full Screen       ⌃⇧3
Copy Text (OCR)                     ← disabled if no capture
---
More ▸
  Repeat Last Area
  Delayed Capture ▸
    Delayed Area (3s)
    Delayed Full Screen (3s)
    [Cancel Countdown]
  ---
  Copy as Markdown                  ← disabled if no capture
  Copy with Citation                ← disabled if no capture
  Annotate Last                     ← disabled if no capture
  Pin Screenshot                    ← disabled if no capture
  ---
  Preset: [name] ▸
---
History
---
Preferences...            ⌘,
Check for Updates...
Quit Caloura              ⌘Q
```
