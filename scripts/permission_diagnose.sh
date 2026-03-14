#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.caloura.app"
APP_PATH="/Applications/Caloura.app"
DERIVED_APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -type d -name Caloura.app 2>/dev/null | head -n 1 || true)"

if [[ -n "$DERIVED_APP" && ! -f "$DERIVED_APP/Contents/Info.plist" ]]; then
  DERIVED_APP=""
fi

if [[ -z "$DERIVED_APP" ]]; then
  while IFS= read -r candidate; do
    if [[ -f "$candidate/Contents/Info.plist" ]]; then
      DERIVED_APP="$candidate"
      break
    fi
  done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 8 -type d -name Caloura.app 2>/dev/null)
fi

echo "== Caloura Screen Recording Diagnostics =="
echo "Date: $(date)"
echo ""

print_codesign() {
  local target="$1"
  if [[ -z "$target" || ! -d "$target" ]]; then
    return
  fi
  echo "--- Signature: $target ---"
  codesign -dvv "$target" 2>&1 | sed -n '1,20p'
  echo "Designated Requirement:"
  codesign -dr - "$target" 2>&1 | sed -n '1,3p'
  echo ""
}

echo "Bundle ID: $BUNDLE_ID"
echo "Public app path exists: $([[ -d "$APP_PATH" ]] && echo yes || echo no)"
echo "DerivedData app found: $([[ -n "$DERIVED_APP" ]] && echo yes || echo no)"
echo ""

print_codesign "$APP_PATH"
print_codesign "$DERIVED_APP"

LOG_PREDICATE='subsystem == "com.caloura.app" && (category == "ScreenCapture" || category == "Permission" || category == "Onboarding" || category == "Launch")'

echo "--- Recent Installed-App Permission Logs (last 4h) ---"
/usr/bin/log show \
  --style compact \
  --last 4h \
  --predicate "$LOG_PREDICATE && process != \"xctest\"" \
  | tail -n 200 || true
echo ""

echo "--- Recent Test-Host Permission Logs (last 4h, informational only) ---"
/usr/bin/log show \
  --style compact \
  --last 4h \
  --predicate "$LOG_PREDICATE && process == \"xctest\"" \
  | tail -n 100 || true
echo ""

echo "--- Actionable Next Steps ---"
echo "1. If /Applications and DerivedData signatures differ, test with only one build running."
echo "2. Prefer /Applications/Caloura.app for end-user verification."
echo "3. Ignore the test-host section unless you are debugging the XCTest permission fixtures."
echo "4. In System Settings -> Privacy & Security -> Screen & System Audio Recording:"
echo "   - Remove stale Caloura entries if present."
echo "   - Re-enable permission for the build you are launching."
echo "5. Relaunch Caloura after granting permission."
echo "6. If prompts persist, share the installed-app log section above."
