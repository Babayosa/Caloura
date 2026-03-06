# Task 06: Scroll Capture Engine V2

## Objective
Replace the legacy heuristic scroll-capture loop with a viewport-locked, displacement-based engine that is reliable on long web feeds and has a first-class manual fallback.

## Context
- Depends on: task-05
- Blocking: none

## Specification
- Rebuild scroll capture around:
  - viewport detection before scrolling
  - pixel-aligned locked capture rects
  - adaptive displacement-based scrolling
  - absolute frame placement instead of overlap clipping
  - seam-aware stitching with sticky-header handling
  - guided manual fallback
- Simplify exposed settings to `scrollToTop` and `maxHeight`.
- Upgrade the progress overlay to show mode/phase and allow manual switching / finish.
- Add end-to-end synthetic engine tests that cover:
  - long-feed bottom reach
  - seam-free separator handling
  - sticky headers
  - no-scroll targets
  - manual fallback/manual finish
  - cancellation
  - max-height termination

## Acceptance Criteria
- [x] Automatic long-feed capture reaches the bottom in synthetic end-to-end tests.
- [x] Separator-line fixtures stitch without visible seams.
- [x] Sticky-header captures avoid header duplication.
- [x] Manual fallback is available and tested.
- [x] `swift build`, `swiftlint lint --quiet`, and `swift test` pass.
- [x] `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData` passes.

## Notes
- Validation still emits pre-existing Swift 6 sendability warnings in the app target; they do not currently fail builds.
