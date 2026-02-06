# Task 19 — Onboarding UI Redesign (Warmer, Friendlier)

Date: 2026-02-06
Owner: Caloura Engineering
Status: Complete

## Plan Checklist

### Implementation
- [x] 1. Window size: 500x400 → 540x460 (both `.frame()` and `WindowConfig`)
- [x] 2. Warm background gradient (ZStack, 4% orange tint at bottom)
- [x] 3. Progress indicator: bar → animated dot stepper
- [x] 4. Permission step: hero app icon (80x80, shadow, scale-in) + material card
- [x] 5. Permission step: status icons per state (contextual SF Symbols)
- [x] 6. First capture step: green checkmark with glow + `.symbolEffect(.bounce)`
- [x] 7. First capture step: shortcuts in material card with descriptions
- [x] 8. First capture step: "Take Your First Screenshot" as `.borderedProminent .controlSize(.large)`
- [x] 9. Navigation footer: chevron icons, Finish as `.bordered`, animation 0.3s
- [x] 10. Copy changes per plan spec

### Verification
- [x] V1. `swift build` — clean
- [x] V2. `swift test` — 224 tests, 0 failures
- [x] V3. `swiftlint lint --quiet` — zero warnings

## Verification / Evidence

```
$ swift build
Build complete! (0.19s)

$ swift test
Executed 224 tests, with 0 failures (0 unexpected) in 4.206 (4.225) seconds

$ swiftlint lint --quiet
(no output — clean)
```

## Files Changed

- `Caloura/UI/OnboardingView.swift` — Main view: warm gradient background, dot stepper, app icon hero, navigation footer with chevron icons, window 540x460
- `Caloura/UI/OnboardingView+Steps.swift` — NEW: extension with step content views (permission step with material card, first capture step with glow checkmark + shortcuts card)
- `Caloura.xcodeproj/project.pbxproj` — Added OnboardingView+Steps.swift to project

## Summary of Visual Changes

1. **Window:** 500x400 → 540x460 for more breathing room
2. **Background:** Warm gradient (windowBackground → 4% orange tint at bottom)
3. **Progress:** Bar → dot stepper with labels ("Setup"/"Ready"), spring animation
4. **Permission step:** App icon (80x80, shadow, scale-in animation) + "Welcome to Caloura" + `.ultraThinMaterial` permission card with contextual status icons
5. **First capture step:** Green checkmark with radial glow + `.symbolEffect(.bounce)` + material shortcuts card with descriptions + "Take Your First Screenshot" as `.borderedProminent .controlSize(.large)`
6. **Footer:** Back/Continue/Finish buttons with chevron icons, Finish as `.bordered` (secondary), animation 0.3s
7. **Copy:** Updated per plan spec
