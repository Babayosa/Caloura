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
- If Screen Recording already looks enabled, onboarding silently validates it in the background and keeps the first-capture CTA as the primary action
- Return from System Settings triggers an automatic re-validation loop that trusts live ScreenCaptureKit validation before stale CoreGraphics state, then resumes the pending first capture on success
- If macOS still stays ambiguous after the post-Settings grace window, Caloura performs one automatic relaunch and resumes the pending first capture on the next launch
- Stored history about a previously working app copy is advisory only; if the Screen Recording record is gone, Caloura still issues a real system permission request so the app reappears in System Settings
- The repaired/completed permission UI is only shown after a live validation path succeeds; stale CG for the same app copy stays in validation/repair instead of pretending capture is ready
- Stale permission records are treated as a separate repair state from plain denial, but only after a real capture validation path fails
- Accessibility remains deferred to Scroll Capture only

## Screen Recording Troubleshooting

If capture fails after permission looks enabled:
1. Use **only one installed copy** while testing (`/Applications/Caloura.app` recommended).
2. In **System Settings > Privacy & Security > Screen & System Audio Recording**, ensure the current build is enabled.
3. Return to Caloura and let the automatic re-validation finish. Caloura will relaunch itself once if macOS still keeps stale in-process state.
4. If Caloura says permission needs validation for this installed copy, run the in-app live check again instead of trusting the passive toggle alone.
5. If the first capture still fails after the automatic retry/relaunch, use the in-app repair flow or run `scripts/permission_diagnose.sh`.

### Build Identity Mismatch (Xcode vs /Applications)

macOS can treat different signatures/paths as separate apps. If permission seems granted but capture still fails:
- Prefer `/Applications/Caloura.app` for public validation.
- Re-grant permission for the exact build you launched only after a real capture attempt fails.

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
- local pre-release validation stays in `scripts/release_ready.sh`
- live appcast validation happens in `scripts/publish.sh` after the site repo is updated
- `Release Smoke` GitHub Actions runs the signed packaging flow on a pinned Xcode runner before publish

## Public Download QA

Use the runbook in `tasks/public-download-qa-runbook.md` for full public download, onboarding, permission, and trial checks.
Quarantine is preserved by default so Gatekeeper behavior stays visible; set `STRIP_QUARANTINE=1` only when you explicitly want a local-only install without quarantine.

## License

Proprietary software.
