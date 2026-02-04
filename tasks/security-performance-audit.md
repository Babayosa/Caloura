# Security + Performance Audit (v1.0.6)

## Scope

- Capture smoothness and start latency
- No-runtime-keychain-prompt behavior
- Local encrypted history storage safety
- Release verification readiness for "fastest/simplest/safest" claims

## Risk Table

| Area | Current State | Risk | Mitigation In Code | Residual Risk |
| --- | --- | --- | --- | --- |
| License persistence | Stored locally for frictionless runtime use | Local preference-domain extraction on compromised host | No startup keychain prompt path; activation still server-validated at Gumroad verify endpoint | Local compromise remains high impact |
| History payload | AES-GCM encrypted at `Application Support/Caloura/history.enc` | Permission drift could broaden file access | Startup audit logs for expected `0700`/`0600` permissions | Drift persists until next audit/save |
| History encryption key | Local key file at `Application Support/Caloura/security/history.key` | Key and ciphertext on same machine | Restricted file permissions + startup drift logging | Physical/local compromise remains high impact |
| Screen recording checks | Passive CG checks + user-initiated functional checks | Prompt-loop regression | No passive permission request path; deduped failure guidance | OS-level TCC behavior can vary across signatures |
| Onboarding permission UX | 2-step flow, soft-gated permission step | Confusing CTA duplication or repeated checks | Single onboarding settings-entry path (`Grant Permission`) + explicit `Check Again` + auto-check progress feedback | User can still deny permission and delay capture readiness |

## Permission Invariants (Expected)

- `~/Library/Application Support/Caloura/security` -> `0700`
- `~/Library/Application Support/Caloura/security/history.key` -> `0600`
- `~/Library/Application Support/Caloura/history.enc` -> `0600`

## Onboarding Permission UX Validation

- No redundant onboarding `Open System Settings` button.
- `Grant Permission` starts the OS flow and shows auto-check progress.
- `Check Again` remains available for explicit re-validation.
- No permission dialog loops under repeated capture attempts.

## No-Keychain Prompt Audit Checklist

- Startup: no keychain prompt
- Onboarding: no keychain prompt
- First capture: no keychain prompt
- Open History window: no keychain prompt
- Open License tab: no keychain prompt

## Performance KPI Targets

- `overlay_visible` p95:
  - single display <= 80 ms
  - multi-display <= 120 ms
- `total` (hotkey to clipboard-ready) p95 <= 350 ms
- `history_window_open` p95 <= 120 ms

## Release Evidence Checklist

- Public ZIP version, appcast version, and internal app version are aligned
- Appcast top item points to `Caloura-1.0.6.zip` with matching signature/length
- Release guard passes:
  `RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6`

## How To Collect Evidence

```bash
scripts/perf_audit.sh --minutes 30 --label local-pass
scripts/public_download_qa.sh --version 1.0.6 verify
```

The perf script writes CSV + Markdown summaries under `build/perf-audit/`.
