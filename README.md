# Caloura

Caloura is a fast macOS menu-bar screenshot tool for area, window, and full-screen capture.

## Highlights

- Area, window, and full-screen capture (multi-display aware)
- Smart crop + OCR pipeline
- Annotation and pinning workflows
- Searchable history with encrypted-at-rest payload storage
- Sparkle-based in-app updates for direct distribution

## Onboarding And Permissions

Caloura uses a **2-step onboarding** flow:
1. Screen Recording permission (soft-gated)
2. First capture quick-start

Permission step behavior:
- `Continue` is always available (no hard block)
- Primary action path is `Grant Permission`
- Explicit recheck is `Check Again`
- After grant, onboarding shows an auto-check progress state

## Screen Recording Troubleshooting

If capture fails after permission looks enabled:
1. Use **only one build lane** while testing (`/Applications/Caloura.app` recommended).
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
- final zipped artifact version parity

Guard-only check:

```bash
RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6
```

For the public website/appcast release flow (v1.0.6 process), use:
- app build + notarization: `scripts/release.sh`
- public artifact verification: `scripts/public_download_qa.sh --version 1.0.6 verify`

## Public Download QA

Use the runbook in `tasks/public-download-qa-runbook.md` for full public download, onboarding, permission, and trial checks.

## License

Proprietary software.
