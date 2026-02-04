# Caloura — Current Project Plan (v1.0.6)

## Current State

- Public release `1.0.6` is built, notarized, and published via `caloura.app` appcast/download flow.
- Permission architecture is loop-hardened:
  - passive lifecycle checks are non-interactive
  - user-initiated validation drives functional checks
  - capture failure guidance is cooldown/dedupe protected
- Onboarding is 2-step and soft-gated:
  - Step 1: Screen Recording permission
  - Step 2: First capture quick-start
- Permission step uses a single grant path (`Grant Permission`) plus explicit recheck (`Check Again`), with auto-check progress feedback after grant.
- Runtime keychain prompt dependency has been removed from normal startup/onboarding/capture/history/license flows.
- Screenshot history is encrypted at rest with file-backed storage in Application Support.
- Release process includes guardrails for tag/version/artifact consistency.

## Active Risks

1. **Build identity confusion (Xcode vs /Applications)**
- macOS TCC can authorize one signed build while denying another.
- Mitigation: mismatch guidance + `scripts/permission_diagnose.sh` + QA dual-lane matrix.

2. **Local-host data extraction risk**
- License state is locally persisted for frictionless runtime behavior.
- Mitigation: keep server-side activation checks; continue reviewing secure-local-store options.

3. **Performance claim drift**
- "Fastest" claim requires repeatable evidence over time.
- Mitigation: keep perf audit cadence with KPI tracking and release evidence capture.

## Next 3 Priorities

1. **Release confidence loop**
- Run public-download QA and performance sampling on each candidate before promotion.

2. **Permission UX final polish**
- Validate mixed-build scenarios and tighten copy only if real-user testing surfaces confusion.

3. **Security hardening roadmap**
- Evaluate practical upgrade path for stronger local license-state protection without reintroducing onboarding friction.

## Release Checklist (Current Standard)

1. Run tests:
- `xcodebuild -scheme Caloura -destination 'platform=macOS' test`

2. Run release guard:
- `RELEASE_GUARD_ONLY=1 RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6`

3. Build/notarize artifact:
- `RELEASE_TAG=v1.0.6 ./scripts/release.sh 1.0.6`

4. Publish and verify public artifact/appcast:
- `scripts/public_download_qa.sh --version 1.0.6 verify`

5. Perform manual onboarding/permission smoke:
- confirm 2-step flow
- confirm single permission entry path + auto-check feedback
- confirm no permission dialog loops

## Decisions Log (Short)

- Keep **Screen Recording** as the only required OS permission.
- Preserve **soft-gated onboarding** to minimize first-run friction.
- Keep **singleton/module architecture** intact; avoid broad rewrites during stabilization.
- Prefer **non-interactive/passive checks** unless the user explicitly initiates permission validation.
- Enforce **release tag/version parity** with guard checks before packaging.
