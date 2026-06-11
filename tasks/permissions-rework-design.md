# Permissions Rework — Design (2026-06-11)

Owner asked for a root-cause rework of the Screen Recording permission system ("so many problems with it in the past"). Basis: deep recon of PermissionCoordinator (875 lines) + 15-phase pain history reconstructed from lessons/git.

## Root causes (ranked, from recon)

- **H1 Signal ambiguity:** CGPreflight and live SCK probe can disagree for 0–10s after any TCC change. Six historical patches are variants of "we believed the wrong signal." The disambiguation context lives in ephemeral in-memory state that dies on relaunch.
- **H2 Unserialized publication:** `refreshPassiveStatus()`/`primeIfPermissionGranted()` are NOT routed through `serializedValidation()` and can overwrite `permissionUIModel` mid-repair (the `diagnosedFailure` struct was a band-aid for one instance of this).
- **H3 State sprawl:** 11 separate state variables (5 UserDefaults keys + 6 in-memory) that must stay mutually consistent and consistent with TCC. Clear/reset calls scattered across ~10 sites.
- **H4 God coordinator:** orchestration + policy + persistence + presentation + process control in one 875-line type; every historical patch touched it.
- **H5 Monolithic repair flow:** `handleCapturePermissionFailureCore` is ~130 lines doing probe → classify → repair → alert → reset → relaunch sequentially; 4 historical bugs lived in its branching.
- **H6 Vestigial replayd repair:** SIP-blocked on Tahoe; still adds latency (500ms wait) on every repair path.

## Non-negotiable invariants (hard-won; ALL must survive — tests pin most of them)

1. CGPreflight is advisory only; after an explicit grant attempt, trust live SCK during the 180s request-session window.
2. NEVER use historical working state to bypass `CGRequestScreenCaptureAccess()` (post-tccutil-reset re-request must happen or the app vanishes from System Settings).
3. Interactive validation paths must serialize (no interleaved validation/repair).
4. Stateful flags: defer-based clearing, recovery API, observable early-returns (CLAUDE.md rule).
5. A hard diagnosis (.needsRelaunch/.staleRecord) must not be reverted by a passive refresh.
6. Pending capture resume arms only when a relaunch is actually requested; cleared on every other exit.
7. replayd restart stays best-effort, never gates recovery.
8. Only `.working` completes onboarding.
9. Stale-record detection keys on signing identity (trustedSigningKey), never executable path.
10. Missing entitlements → `.configurationFailed`, never denial/repair.
11. Public API used by call sites (CalouraApp, CapturePipeline, OnboardingView, AppCommandController) and the 13 permission test files (~2,700 lines) keeps working — tests are the regression net and must stay green UNMODIFIED except where a stage explicitly adds tests.

## Target architecture

```
PermissionEvidence (new, pure value)
  one snapshot: cgPreflight, sckProbeOutcome, identityMatch, requestSessionActive,
  liveValidatedThisProcess, diagnosedFailure — gathered at ONE point per evaluation.

PermissionStore (new, single owner of ALL durable + session state)
  - durable: one Codable struct in UserDefaults (lastWorkingIdentity, pendingResume,
    lastAutoRepairRelaunchAt, lastBlockingAlertAt ← cooldown now persists, fixing
    cross-relaunch alert spam)
  - session: requestSession, liveValidatedFingerprint, diagnosedFailure
  - explicit lifecycle methods (recordWorking, armPendingResume, takePendingResume,
    noteAlertShown, ...) — no other type touches these keys.

PermissionStatusCore (existing, grows slightly)
  pure rules: PermissionEvidence -> ScreenRecordingState + UI model (keeps name).

PermissionRecoveryPlanner (new, pure)
  (state, evidence, cooldowns, capabilities) -> [RecoveryStep]
  RecoveryStep enum: .probeSCK(retries:), .restartReplayd(bestEffort), .presentAlert(kind),
  .resetTCC, .relaunch, .openSettings, .none — replaces the 130-line branch forest.

PermissionCoordinator (stays, shrinks to facade ~300 lines)
  - owns the ONLY publication path: every status/UI-model write goes through
    publish(_:) which enforces: no downgrade of diagnosis by passive evidence,
    no publication while a serialized flow holds the gate (passive evidence is
    queued/merged instead of racing).
  - executes RecoveryStep lists from the planner via injected effectors
    (existing closure-DI seams in ScreenCaptureManager+Permission).
  - public API unchanged: refreshPassiveStatus, runUserInitiatedValidation,
    revalidateAfterSettingsReturn, handleCapturePermissionFailure,
    primeIfPermissionGranted, armPendingCaptureResume, takePendingCaptureResumeIfFresh.
```

Replayd on macOS 26+: still attempted (invariant 7) but with no post-wait when the
kickstart process exits non-zero immediately (H6 latency fix).

## Stages (each = compiling, full suite green, strict lint clean, atomic commit)

- **S1 PermissionStore**: consolidate the 5 UserDefaults keys + session state; persist
  alert cooldown. New PermissionStoreTests (lifecycle, persistence round-trip,
  cooldown across simulated relaunch). Coordinator delegates, behavior identical.
- **S2 Publication gate**: single publish() path; passive refresh becomes
  evidence-merge that cannot downgrade diagnosis or interrupt an in-flight serialized
  flow. New tests: passive-refresh-during-repair keeps .repairing/diagnosis (the H2
  race, currently untested); onboarding polling + didBecomeActive double-invocation.
- **S3 RecoveryPlanner**: extract decision tree from handleCapturePermissionFailureCore
  + revalidateAfterSettingsReturnCore into pure planner; coordinator executes steps.
  Planner unit tests enumerate every (state × evidence × cooldown) cell. Replayd
  fast-skip. Existing repair-flow tests must pass unmodified.
- **S4 Facade slim-down + docs**: move remaining helpers into the new units; update
  codex/CODEMAP.md permission section; PermissionCoordinator ≤ ~400 lines.

## Acceptance (whole rework)

- All 13 existing permission test files green UNMODIFIED (except documented helper
  import changes); full suite + strict lint + coverage gate green in CI.
- New tests cover: H2 race, polling double-invocation, cooldown persistence,
  planner decision table.
- Each invariant above has at least one test naming it (add a comment // INVARIANT-n).
- CI green on the PR; PermissionCoordinator.swift ≤ ~400 lines at the end.
