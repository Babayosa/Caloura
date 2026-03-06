# Task 09: Release Hardening Continuation

## Goal
Continue the 10/10 release-hardening program from the clean local-validation state, remove the remaining Xcode warning-bar debt, and push the canonical release gate as far as possible before external release-environment blockers take over.

## Scope
- Clear the remaining app-scheme `xcodebuild test` warnings
- Keep the local validation stack green
- Run `scripts/release_ready.sh --guard-only` and capture the first real non-local blocker
- Reduce remaining low-level safety debt in AX / Security bridge wrappers
- Update codex tracking files with the actual state of the release-hardening continuation

## Changes
- Refactored XCTest lifecycle isolation in:
  - `CalouraUITests/CalouraUITests.swift`
  - `CalouraTests/CaptureTests/ScreenCaptureManagerTests.swift`
  - `CalouraTests/AppTests/URLSchemeHandlerTests.swift`
  - `CalouraTests/AppTests/LicenseManagerSignedBackendTests.swift`
- Replaced the remaining type-ID-guarded `unsafeBitCast` usage with normal forced casts in:
  - `Caloura/Capture/ScrollCaptureEngine.swift`
  - `Caloura/Capture/PermissionCoordinator.swift`
- Fixed manual scroll finish so the engine performs one final settled capture before returning `.manualFinished`, eliminating an Xcode-side flake that truncated the last viewport by 2 px in the synthetic test surface
- Revalidated the release-preflight path and captured the current external blocker boundary

## Validation
- `swift build`
- `swiftlint lint --quiet`
- `swift test`
- `xcodegen generate`
- `xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64'`
- `xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug -derivedDataPath .build/DerivedData -enableCodeCoverage YES -skip-testing:CalouraUITests -destination 'platform=macOS,arch=arm64'`
- `scripts/release_ready.sh --guard-only`
- Re-ran `swift test --filter ScrollCaptureEngine`, `swift test`, `xcodebuild build`, and `xcodebuild test` after the manual-finish race fix

## Evidence
- Warning-free Xcode test log: `build/release-ready/xcodebuild-test-warning-check-4.log`
- Canonical guard run now fails at: `Release configuration is missing CALOURA_LICENSE_ENTITLEMENT_URL.`

## Next Blockers
1. Supply Release entitlement backend configuration for `CALOURA_LICENSE_ENTITLEMENT_URL` and `CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY`
2. Provision the `Caloura-Notarize` notarytool keychain profile on the release machine
3. Publish live Sparkle appcast metadata that matches the bundle’s minimum macOS version
