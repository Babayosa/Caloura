#!/usr/bin/env bash
set -euo pipefail

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
XCODE_APP="/Applications/Xcode.app"
XCTRUNNER_APP="$XCODE_APP/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

[[ -d "$XCODE_APP" ]] || fail "Xcode.app not found at $XCODE_APP."
[[ -d "$XCTRUNNER_APP" ]] || fail "macOS XCTRunner.app not found at $XCTRUNNER_APP."

if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]; then
  fail "macOS UI tests must run from an interactive Aqua login session, not over SSH."
fi

if [[ "$CONSOLE_USER" != "$CURRENT_USER" ]]; then
  fail "Current user '$CURRENT_USER' does not own /dev/console (console user: '$CONSOLE_USER'). UI automation requires the logged-in desktop session."
fi

if ! launchctl print "gui/$CURRENT_UID" >/dev/null 2>&1; then
  fail "No Aqua login session is available for gui/$CURRENT_UID."
fi

if ! pgrep -x Dock >/dev/null 2>&1; then
  fail "Dock is not running for the current user. UI automation requires a normal Finder/Dock desktop session."
fi

cat <<EOF
UI automation environment preflight passed.
Xcode: $XCODE_APP
XCTRunner: $XCTRUNNER_APP

If the dedicated UI test pass still fails with "Timed out while enabling automation mode",
grant Accessibility access to Xcode and the Xcode UI-testing helper app in:
System Settings > Privacy & Security > Accessibility
EOF
