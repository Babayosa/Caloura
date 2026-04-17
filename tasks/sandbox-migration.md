# App Sandbox Migration — deferred to v3.0

## Status

Deferred from the production-readiness overhaul (Phase 2 plan item P2,
`.claude/plans/agile-conjuring-hollerith.md`). No user-facing benefit for a
Developer ID distribution today, and the required refactors carry real risk.

## Blast radius

1. **`FileOrganizer` — security-scoped bookmarks.** The user picks
   `saveDirectory` via `NSOpenPanel` today; when sandboxed the path must be
   persisted as a security-scoped bookmark and re-resolved on each launch.
   Every `FileManager` call that currently takes a plain path (`ensureBaseDirectory`,
   `overwrite`, `save`, path-safety checks) needs to flow through
   `URL.startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`
   paired correctly.
2. **Sparkle XPC services.** Sparkle ships separate XPC helpers for download
   and installation when sandboxed. Each helper needs its own code-signing
   identity, entitlements, and Info.plist entries. The site's appcast signing
   flow is unaffected, but the published pipeline (`scripts/publish.sh`)
   should verify the XPC helpers are bundled.
3. **Hardened-runtime + sandbox compatibility pass.** `com.apple.security.app-sandbox`
   combined with the existing `com.apple.security.screen-capture` and
   Accessibility prompts needs verification across macOS 14 / 15 / 26.
4. **`KeychainHelper` regressions.** Sandbox restricts keychain access groups
   and confounds legacy-keychain-migration paths. Caloura currently does
   *not* use Keychain for runtime persistence (encrypted via `HistoryCrypto`
   instead), but any remaining legacy migration calls must remain no-op-safe.

## Cost estimate

3–5 engineering days, plus 2–3 days of cross-OS QA.

## Pre-work checklist (before starting the migration)

- [ ] Audit all `URL` / `FileManager` call sites outside the chosen save
      directory — anything outside needs an explicit entitlement or bookmark.
- [ ] Inventory Sparkle's current XPC setup (check `.build/xcode/SourcePackages/checkouts/Sparkle/Sandboxing.md`).
- [ ] Verify the update-channel plumbing from Phase 6 Polish 3 (Sparkle beta
      channel) works cleanly with sandboxed XPC helpers.
- [ ] Decide whether to keep the "Pictures/Caloura" default save path or move
      to the app's Application Support container (simpler but visible-folder
      regression for existing users).

## When to revisit

When one of:
- Distribution moves to MAS (Mac App Store requires sandbox).
- Notarization rejections cite sandbox / entitlement drift.
- macOS 27 tightens non-sandboxed Developer ID capabilities.

Otherwise: keep shipping without sandbox. The privacy positioning (local-only
data, no telemetry) is stronger with the current architecture's direct disk
access than with the user-visible "sandboxed app" label.
