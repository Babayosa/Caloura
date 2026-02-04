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

echo "--- Recent Permission Logs (last 4h) ---"
/usr/bin/log show \
  --style compact \
  --last 4h \
  --predicate 'subsystem == "com.caloura.app" && (category == "ScreenCapture" || category == "Permission" || category == "Onboarding" || category == "Launch")' \
  | tail -n 200 || true
echo ""

echo "--- Actionable Next Steps ---"
echo "1. If /Applications and DerivedData signatures differ, test with only one build running."
echo "2. Prefer /Applications/Caloura.app for end-user verification."
echo "3. In System Settings -> Privacy & Security -> Screen & System Audio Recording:"
echo "   - Remove stale Caloura entries if present."
echo "   - Re-enable permission for the build you are launching."
echo "4. Relaunch Caloura after granting permission."
echo "5. If prompts persist, share the log section above."
