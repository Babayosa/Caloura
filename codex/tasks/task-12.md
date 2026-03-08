# Task 12: Screen Recording Recovery + Neutral DMG Surface

## Objective
Fix the false-negative Screen Recording onboarding path so granted permission is recognized reliably on the installed app copy, and replace the DMG install window’s reused Caloura artwork with a neutral professional background.

## Scope
- Remove passive fingerprint mismatch as a blocking onboarding signal
- Use a typed minimal screenshot probe for ScreenCaptureKit validation
- Keep onboarding on the first-capture CTA until a real validation/capture failure persists through one silent repair attempt
- Auto-resume the pending first capture after Screen Recording is granted
- Replace the DMG background source with a checked-in neutral PNG and make the release script require it

## Out of Scope
- Reworking the install-first onboarding step count or overall window structure
- Changing Sparkle artifact behavior or the DMG Finder layout geometry
- Replacing the broader permission troubleshooting flow outside Screen Recording

## Validation
- `swift build`
- `swiftlint --quiet`
- `swift test`
- Targeted `xcodebuild test` slice for Screen Recording onboarding and ScreenCapture permission tests

## Notes
- The current machine has multiple Caloura copies (`/Applications`, Downloads, DerivedData, archive/export products), so the implementation must remain stable in mixed-copy environments.
- The new DMG background asset is generated and checked in under `scripts/assets/`.
