# Public Download QA Runbook (Onboarding + Auth + 7-Day Trial)

Reference date for trial simulation: **February 4, 2026**.

## Quick Start

```bash
# 1) Verify artifact + appcast, install, reset state, launch
scripts/public_download_qa.sh --version 1.0.7 all-cli

# 2) Print manual validation checklist
scripts/public_download_qa.sh --version 1.0.7 manual-checks

# 3) After doing ~20 captures, summarize performance logs
scripts/perf_audit.sh --minutes 30 --label v1.0.7-local
```

Optional Gatekeeper validation:

```bash
KEEP_QUARANTINE=1 scripts/public_download_qa.sh --version 1.0.7 install
spctl --assess --type execute -vv /Applications/Caloura.app
```

## Individual Commands

```bash
scripts/public_download_qa.sh --version 1.0.7 verify
scripts/public_download_qa.sh --version 1.0.7 install
scripts/public_download_qa.sh --version 1.0.7 clean-room-reset
scripts/public_download_qa.sh --version 1.0.7 launch
```

## Trial Simulation Commands

```bash
# Fresh baseline
scripts/public_download_qa.sh --version 1.0.7 trial-baseline

# Day 4 equivalent (first launch date = 2026-01-31 10:00:00 +0000)
scripts/public_download_qa.sh --version 1.0.7 trial-day4

# Expired equivalent (first launch date = 2026-01-27 10:00:00 +0000)
scripts/public_download_qa.sh --version 1.0.7 trial-expired

# Remove overrides and return to normal
scripts/public_download_qa.sh --version 1.0.7 trial-reset
```

## Expected Outcomes

- Manual download is the DMG, while the Sparkle appcast still points to the ZIP.
- The DMG opens with `Caloura.app` and an `Applications` shortcut in a drag-to-install layout.
- First launch from `/Applications` opens directly to `Take your first screenshot`, not a permission wizard.
- Screen Recording is requested only when the first real capture starts.
- Returning from System Settings triggers an automatic permission re-check.
- Stale-copy issues show explicit `/Applications/Caloura.app` repair guidance instead of generic denial.
- Scroll Capture is the only path that asks for Accessibility.
- No keychain password prompt appears on startup, onboarding, capture, License, or History.
- Permission failure shows recovery guidance once; no prompt/dialog loops.
- Trial states align with simulated dates and show expected day counts/expired behavior.

## Notes

- Test `/Applications/Caloura.app` (public app), not the Xcode debug run.
- A clean macOS user account is recommended for the first pass.
- For cursor smoothness, record the screen at high FPS and verify no crosshair-to-arrow flicker at capture entry.

## Dual-Build Permission Matrix

Run both lanes when diagnosing repeated permission prompts:

1. Public lane (`/Applications/Caloura.app`):
- Confirm capture works without repeated permission dialogs.
- Confirm install-first onboarding lands on first capture, then permission recovery if needed.

2. Xcode lane (DerivedData app):
- Launch from Xcode and run one capture.
- Confirm mismatch guidance appears at most once.
- Confirm no modal permission alert loops during repeated captures.

If behavior differs between lanes, run:

```bash
scripts/permission_diagnose.sh
```
