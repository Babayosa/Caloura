# Public Download QA Runbook (Onboarding + Auth + 7-Day Trial)

Reference date for trial simulation: **February 4, 2026**.

## Quick Start

```bash
# 1) Verify artifact + appcast, install, reset state, launch
scripts/public_download_qa.sh --version 1.0.6 all-cli

# 2) Print manual validation checklist
scripts/public_download_qa.sh --version 1.0.6 manual-checks

# 3) After doing ~20 captures, summarize performance logs
scripts/perf_audit.sh --minutes 30 --label v1.0.6-local
```

## Individual Commands

```bash
scripts/public_download_qa.sh --version 1.0.6 verify
scripts/public_download_qa.sh --version 1.0.6 install
scripts/public_download_qa.sh --version 1.0.6 clean-room-reset
scripts/public_download_qa.sh --version 1.0.6 launch
```

## Trial Simulation Commands

```bash
# Fresh baseline
scripts/public_download_qa.sh --version 1.0.6 trial-baseline

# Day 4 equivalent (first launch date = 2026-01-31 10:00:00 +0000)
scripts/public_download_qa.sh --version 1.0.6 trial-day4

# Expired equivalent (first launch date = 2026-01-27 10:00:00 +0000)
scripts/public_download_qa.sh --version 1.0.6 trial-expired

# Remove overrides and return to normal
scripts/public_download_qa.sh --version 1.0.6 trial-reset
```

## Expected Outcomes

- Onboarding has exactly 2 steps.
- Permission step is soft-gated: `Continue` works without permission.
- Permission step shows only `Grant Permission` and `Check Again`.
- `Grant Permission` is the single settings-entry path in onboarding.
- Auto-check progress appears immediately after `Grant Permission`.
- Final step has both `Take First Screenshot` and `Finish`.
- Finishing onboarding returns to ready menu-bar state (no auto-open Preferences).
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
- Confirm onboarding permission step shows stable state after one relaunch.

2. Xcode lane (DerivedData app):
- Launch from Xcode and run one capture.
- Confirm mismatch guidance appears at most once.
- Confirm no modal permission alert loops during repeated captures.

If behavior differs between lanes, run:

```bash
scripts/permission_diagnose.sh
```
