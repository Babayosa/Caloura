# Caloura

Caloura is a fast macOS menu-bar screenshot tool for area, window, and full-screen capture.

## Highlights

- Area, window, and full-screen capture (multi-display aware)
- Smart crop + OCR pipeline
- Annotation and pinning workflows
- Searchable history with encrypted-at-rest payload storage
- Sparkle-based in-app updates for direct distribution

## Onboarding And Permissions

Caloura now uses an **install-first onboarding** flow:
1. Install the app in `/Applications` before setup continues
2. Launch the installed copy and take the first screenshot
3. Grant Screen Recording only when the first real capture needs it

Permission behavior:
- Screen Recording is checked in context when capture starts
- Return from System Settings triggers an automatic re-validation loop
- Stale permission records are treated as a separate repair state from plain denial
- Accessibility remains deferred to Scroll Capture only

## Screen Recording Troubleshooting

If capture fails after permission looks enabled:
1. Use **only one installed copy** while testing (`/Applications/Caloura.app` recommended).
2. In **System Settings > Privacy & Security > Screen & System Audio Recording**, ensure the current build is enabled.
3. Relaunch Caloura.
4. If you alternate between Xcode and public builds, run `scripts/permission_diagnose.sh`.

### Build Identity Mismatch (Xcode vs /Applications)

macOS can treat different signatures/paths as separate apps. If permission seems granted but capture still fails:
- Prefer `/Applications/Caloura.app` for public validation.
- Re-grant permission for the exact build you launched.

## Data And Security

- **License state**: persisted locally for frictionless runtime (no startup keychain prompt path).
- **History payload**: encrypted with AES-GCM at
  `~/Library/Application Support/Caloura/history.enc`
- **History key**: stored at
  `~/Library/Application Support/Caloura/security/history.key`
- **Permission model**: Screen Recording is the only required OS permission.

## Keyboard Shortcuts (Defaults)

- `Ctrl+Shift+4` Capture Area
- `Ctrl+Shift+5` Capture Window
- `Ctrl+Shift+3` Capture Full Screen
- `Ctrl+Shift+R` Repeat Last Area

All shortcuts are configurable in Preferences.

## Requirements

- macOS 14.0+
- Xcode 15+ (for local development)

## Build And Test

```bash
xcodegen generate
xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug
xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug
```

## Release Guard And Publishing

Versioning is gated by `scripts/release.sh`:
- tag/version alignment (`RELEASE_TAG` / `GITHUB_REF_NAME`)
- exported app version parity
- final ZIP artifact version parity
- final DMG artifact version parity
- signed/notarized/stapled manual-download DMG plus Sparkle ZIP

Guard-only check:

```bash
RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.7 ./scripts/release.sh 1.0.7
```

For the public website/appcast release flow (v1.0.7 process), use:
- app build + notarization: `scripts/release.sh`
- manual-download DMG publish + Sparkle ZIP publish: `scripts/publish.sh`
- public artifact verification: `scripts/public_download_qa.sh --version 1.0.7 verify`

## Public Download QA

Use the runbook in `tasks/public-download-qa-runbook.md` for full public download, onboarding, permission, and trial checks.

## License

Proprietary software.
