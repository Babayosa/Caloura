# App Sandbox Decision

**Status:** Shipping **un-sandboxed** as of 2.4.0. Revisit every major release.
**Last reviewed:** 2026-04-22

## Decision

Caloura ships without the `com.apple.security.app-sandbox` entitlement. `Caloura/Resources/Caloura.entitlements` sets it to `false`. The app is distributed as a Developer ID-signed, notarized DMG via Sparkle (not the Mac App Store). Gatekeeper, Hardened Runtime, and notarization provide the baseline distribution-side protections.

This is a deliberate choice, not an oversight. The rationale, mitigations, and re-evaluation criteria are recorded below.

## Rationale

The core of Caloura is screen capture, history persistence across launches, local OCR, clipboard integration, and auto-update via Sparkle. Each of these interacts with macOS mechanisms whose sandbox interactions have known friction or open questions:

1. **ScreenCaptureKit (SCK)** — Screen Recording is gated through TCC, not through app-sandbox entitlements, so SCK itself works under sandbox per Apple's documentation. Risk is low but has not been measured under sandbox with Caloura's specific capture paths (window picker, multi-display fullscreen, frozen-image overlays).
2. **Sparkle auto-update** — The installer/relaunch helper lifecycle under sandbox requires additional entitlements and possibly XPC carve-outs. Sparkle supports sandboxed apps but the configuration surface is non-trivial and upgrade paths can regress silently.
3. **Login item / Launch at Login** — Currently uses `SMAppService.mainApp` (macOS 13+ API), which is sandbox-compatible, but the error paths (`kSMErrorJobPlistNotFound`, `kSMErrorAuthorizationFailure`) have not been verified inside a sandboxed process.
4. **History file persistence and saved-file opening** — Caloura saves captures to a configurable location and lets users open/export them. Sandbox requires `com.apple.security.files.user-selected.read-write` and possibly security-scoped bookmarks for persistent access across launches.
5. **Clipboard with multiple representations** — No direct sandbox blocker; listed for completeness.

None of these are known blockers — but verifying each under sandbox, with every capture mode and every export path, is the Phase 7 spike work that has not yet been done. Shipping un-sandboxed while we complete that work is a deliberate trade: we accept a larger syscall surface in exchange for a verified, stable feature set in v2.x.

## Threat Model — What We Accept

Because the app is not sandboxed, a compromise of the Caloura process (via a vulnerability in Caloura, its dependencies, or a malicious update) has access to:

- The user's entire file system under their UID (read/write), subject to TCC (which gates sensitive paths like Documents, Desktop, Downloads anyway).
- The clipboard.
- Network (outbound HTTP/HTTPS — used for Sparkle appcast fetch and Gumroad license verification).
- Any process Caloura spawns (the code path is minimal today but not guaranteed nil in the future).

What is **not** expanded by shipping un-sandboxed:

- Screen recording access is still TCC-gated, same as a sandboxed app would be.
- Accessibility API access is TCC-gated, same as sandboxed.
- Input monitoring, keystroke capture, camera, mic: Caloura does not request these entitlements and does not access them.

## Mitigations In Place

The following distribution-side and code-side mitigations partially offset the lack of sandbox isolation:

1. **Developer ID signing + notarization** — every DMG is stapled after Apple notarization. Any binary substitution breaks the signature and Gatekeeper refuses to launch.
2. **Hardened Runtime enabled** — blocks unsigned library injection, disables `DYLD_INSERT_LIBRARIES`, etc. (See the default Xcode-generated entitlements for the full list.)
3. **Sparkle EdDSA signing** — update payloads are signed with an EdDSA key (see `docs/RELEASE-KEYS.md`). Compromising the update channel requires compromising the signing key, not just the appcast host.
4. **No remote code execution paths in-app** — Caloura does not download or execute code at runtime beyond Sparkle's signed installer flow.
5. **No inbound listeners** — the app is outbound-only; no sockets bound, no XPC services published that could be invoked by other processes.
6. **License verification is read-only** — the Gumroad verifier performs `POST` requests with a key; it does not execute server-returned code paths as code.
7. **OCR, embeddings, and metadata generation are local** — no screen content leaves the device except when the user explicitly shares/copies it.

## When to Re-Evaluate

Schedule a Phase 7 spike and revisit this document when any of the following changes:

- **Mac App Store distribution is considered.** MAS requires sandbox; this becomes mandatory, not optional.
- **A new feature introduces process spawning, XPC services, or script execution.** The un-sandboxed threat model expands and the trade-off tilts.
- **Sparkle 3.x or a Sparkle release materially changes the sandbox story.** Currently requires helper configuration; a future release may simplify.
- **A security advisory affects a dependency.** Sandbox would have constrained the blast radius; absence of sandbox makes response more urgent.
- **Annually at minimum.** Add a calendar reminder to review this document against current macOS releases (sandbox semantics shift per-OS).

## Spike Scope (When Executed)

The deferred Phase 7 spike, when run, should:

1. Branch from `main` as `spike/sandbox`.
2. Set `com.apple.security.app-sandbox = true` in `Caloura/Resources/Caloura.entitlements`.
3. Add incremental entitlements as violations surface. Starting set to try:
   - `com.apple.security.files.user-selected.read-write`
   - `com.apple.security.files.downloads.read-write` (for default save path)
   - `com.apple.security.network.client` (for Sparkle + Gumroad)
   - `com.apple.security.device.audio-input` → **not needed**, confirm.
   - `com.apple.security.assets.pictures.read-write` (if user saves to Pictures)
4. Exercise every capture mode (area, window, fullscreen), every save/copy/markdown/citation path, every Sparkle update cycle end-to-end, every login-item toggle, every license state transition.
5. Collect the final entitlement list and record any features that had to be dropped or redesigned.
6. Produce a concrete go/no-go recommendation with migration cost, and update this document.

## References

- Apple: [App Sandbox Design Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/AppSandboxDesignGuide/AboutAppSandbox/AboutAppSandbox.html)
- Apple: [ScreenCaptureKit and Privacy](https://developer.apple.com/documentation/screencapturekit)
- Sparkle: [Sandboxing docs](https://sparkle-project.org/documentation/sandboxing/)
- Project CLAUDE.md — "Caloura / Project Conventions" section.
