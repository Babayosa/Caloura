# Task 11: Install-First Onboarding Refactor

## Objective
Replace the old permission-first onboarding with an install-first flow that stabilizes the app in `/Applications`, defers Screen Recording until the first real capture, and repairs stale permission records without trapping users in a setup maze.

## Scope
- Gate first launch on `/Applications` installation and replace the old `AppMover` alert with a dedicated install screen
- Split passive Screen Recording state from verified working state and distinguish stale-record repair from plain denial
- Rework onboarding UI around `install -> first capture -> contextual permission repair`
- Add lightweight contextual post-activation tips for history, edits, scroll capture, and sharing
- Extend release/publish/public-QA scripts for DMG manual downloads while retaining ZIP for Sparkle

## Out of Scope
- Reworking the Sparkle update mechanism itself
- Replacing the menu bar UI or broader preferences architecture
- Website repository changes outside the publish contract managed from this repo

## Validation
- `swift build`
- `swiftlint --quiet`
- `swift test`
- Targeted `xcodebuild test` slices for onboarding/permission unit tests and the onboarding window system test

## Notes
- `swift build`, `swiftlint`, and `swift test` required escalated execution on this machine because the sandbox blocks the normal Swift/Xcode module-cache paths.
- `swiftlint` now completes, but the repo still contains many warning-level style violations outside this task’s scope.
