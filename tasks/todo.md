# 2-Tier Pricing Model + Preferences UI Overhaul + Landing Page Updates

## Plan

- [x] 1. **AppSettings** — Add `firstLaunchDate`, `licenseKey`, `isLicenseActivated` properties
- [x] 2. **LicenseManager.swift** (new) — Trial tracking, activation state, Gumroad API
- [x] 3. **NagDialog.swift** (new) — Post-trial nag dialog + window controller
- [x] 4. **CalouraApp.swift** — Wire nag into `applicationDidFinishLaunching`
- [x] 5. **PreferencesView.swift** — Shottr-style icon tab bar + License tab
- [x] 6. **Landing page** — Pricing section, nav link, image placeholders, responsive cards
- [x] 7. **LicenseManagerTests.swift** (new) — 12 unit tests for trial/license logic
- [x] 8. **Verification** — Run all tests (66 existing + 12 new), confirm build, document results

## Review / Evidence

### Build
- `xcodebuild build` — **BUILD SUCCEEDED** (no new warnings except pre-existing CGWindowListCreateImage deprecation)
- `xcodegen generate` — project regenerated successfully with 3 new source files auto-discovered

### Tests
- **78 tests executed, 0 failures — TEST SUCCEEDED**
- 66 existing tests: all pass (no regressions)
- 12 new `LicenseManagerTests`: all pass
  - Trial days: day 1 (30), day 15 (15), day 31 (0)
  - Trial expired: within trial (false), after trial (true), when licensed (false)
  - Nag logic: during trial (false), expired+unlicensed (true), expired+licensed (false)
  - Activation state: licensed, trial, expired

### Files Changed/Created
| File | Action |
|------|--------|
| `Caloura/Models/AppSettings.swift` | Modified — 3 new license properties |
| `Caloura/App/LicenseManager.swift` | **New** — Trial tracking, activation state, Gumroad API |
| `Caloura/UI/NagDialog.swift` | **New** — Post-trial nag dialog + window controller |
| `Caloura/App/CalouraApp.swift` | Modified — nag controller + showIfNeeded wiring |
| `Caloura/UI/PreferencesView.swift` | Modified — Shottr-style icon tab bar + License tab |
| `Documents/caloura-site/index.html` | Modified — pricing section, nav links, image slots |
| `Documents/caloura-site/style.css` | Modified — pricing cards, screenshot slots, nav links, responsive |
| `CalouraTests/AppTests/LicenseManagerTests.swift` | **New** — 12 unit tests |
