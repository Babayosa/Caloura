#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Caloura"
BUNDLE_ID="com.caloura.app"
APPCAST_URL="https://caloura.app/appcast.xml"
INSTALL_PATH="/Applications/Caloura.app"
VERSION="${CALOURA_VERSION:-1.0.5}"
COMMAND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --version requires a value"
        exit 1
      fi
      VERSION="$2"
      shift 2
      ;;
    *)
      COMMAND="$1"
      shift
      break
      ;;
  esac
done

DOWNLOAD_URL="https://caloura.app/releases/Caloura-${VERSION}.zip"
ZIP_PATH="${TMPDIR:-/tmp}/Caloura-${VERSION}.zip"
UNZIP_DIR="${TMPDIR:-/tmp}/Caloura-public-${VERSION}"

print_header() {
  echo ""
  echo "==> $1"
}

check_keychain_item() {
  local account="$1"
  if security find-generic-password -s "$BUNDLE_ID" -a "$account" >/dev/null 2>&1; then
    echo "present"
  else
    echo "missing"
  fi
}

verify_public_artifacts() {
  print_header "Phase 1: Verify Public Artifact + Appcast"
  echo "Version under test: ${VERSION}"
  echo "Download URL HEAD:"
  curl -I "$DOWNLOAD_URL"

  echo ""
  echo "Appcast matches (version + URL + sparkle versions):"
  curl -s "$APPCAST_URL" | grep -n "Version ${VERSION}\\|Caloura-${VERSION}\\.zip\\|sparkle:version"
}

install_public_app() {
  print_header "Download + Install Public App"
  rm -f "$ZIP_PATH"
  rm -rf "$UNZIP_DIR"

  curl -L "$DOWNLOAD_URL" -o "$ZIP_PATH"
  mkdir -p "$UNZIP_DIR"
  ditto -x -k "$ZIP_PATH" "$UNZIP_DIR"

  if [ ! -d "$UNZIP_DIR/Caloura.app" ]; then
    echo "ERROR: Expected app not found after unzip: $UNZIP_DIR/Caloura.app"
    exit 1
  fi

  rm -rf "$INSTALL_PATH"
  cp -R "$UNZIP_DIR/Caloura.app" "$INSTALL_PATH"
  xattr -dr com.apple.quarantine "$INSTALL_PATH" || true

  echo "Installed: $INSTALL_PATH"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true
}

clean_room_reset() {
  print_header "Phase 2: Clean-Room Reset"
  pkill -x "$APP_NAME" || true
  defaults delete "$BUNDLE_ID" || true
  tccutil reset ScreenCapture "$BUNDLE_ID" || true
  security delete-generic-password -s "$BUNDLE_ID" -a licenseKey || true
  security delete-generic-password -s "$BUNDLE_ID" -a screenshotHistoryKey || true

  echo "Keychain snapshot after reset:"
  echo "  licenseKey: $(check_keychain_item licenseKey)"
  echo "  screenshotHistoryKey: $(check_keychain_item screenshotHistoryKey)"
}

launch_public_app() {
  print_header "Launch Public App"
  if [ ! -d "$INSTALL_PATH" ]; then
    echo "ERROR: $INSTALL_PATH not found. Run install step first."
    exit 1
  fi

  open -a "$INSTALL_PATH"
  sleep 3

  echo "Running processes:"
  pgrep -fl "$APP_NAME" || true

  echo "Keychain snapshot immediately after launch:"
  echo "  licenseKey: $(check_keychain_item licenseKey)"
  echo "  screenshotHistoryKey: $(check_keychain_item screenshotHistoryKey)"
}

trial_baseline() {
  print_header "Phase 5: Trial Baseline"
  defaults delete "$BUNDLE_ID" firstLaunchDate || true
  defaults write "$BUNDLE_ID" isLicenseActivated -bool false
  security delete-generic-password -s "$BUNDLE_ID" -a licenseKey || true
  pkill -x "$APP_NAME" || true
  open -a "$INSTALL_PATH"
  sleep 2

  echo "firstLaunchDate after launch:"
  defaults read "$BUNDLE_ID" firstLaunchDate || true
  echo "isLicenseActivated:"
  defaults read "$BUNDLE_ID" isLicenseActivated || true
}

trial_day4() {
  print_header "Phase 5: Simulate Day 4 (2026-01-31)"
  defaults write "$BUNDLE_ID" firstLaunchDate -date "2026-01-31 10:00:00 +0000"
  defaults write "$BUNDLE_ID" isLicenseActivated -bool false
  pkill -x "$APP_NAME" || true
  open -a "$INSTALL_PATH"
  sleep 2

  echo "Configured firstLaunchDate:"
  defaults read "$BUNDLE_ID" firstLaunchDate || true
}

trial_expired() {
  print_header "Phase 5: Simulate Expired Trial (2026-01-27)"
  defaults write "$BUNDLE_ID" firstLaunchDate -date "2026-01-27 10:00:00 +0000"
  defaults write "$BUNDLE_ID" isLicenseActivated -bool false
  pkill -x "$APP_NAME" || true
  open -a "$INSTALL_PATH"
  sleep 2

  echo "Configured firstLaunchDate:"
  defaults read "$BUNDLE_ID" firstLaunchDate || true
}

trial_reset() {
  print_header "Phase 5: Reset Trial Overrides"
  defaults delete "$BUNDLE_ID" firstLaunchDate || true
  defaults delete "$BUNDLE_ID" isLicenseActivated || true
  pkill -x "$APP_NAME" || true
  open -a "$INSTALL_PATH"
  sleep 2

  echo "Post-reset state:"
  defaults read "$BUNDLE_ID" firstLaunchDate || true
  defaults read "$BUNDLE_ID" isLicenseActivated || true
}

print_manual_checks() {
  cat <<'MANUAL'

Manual checks to perform now:
1. On first launch, verify onboarding has exactly 2 steps.
2. On permission step, verify Continue works even without granting permission.
3. On second step, verify both "Take First Screenshot" and "Finish" are present.
4. After finishing onboarding, verify Preferences does not auto-open.
5. Verify no keychain password dialog appears at startup, onboarding, capture, License, or History.
6. Open Preferences > License and validate key activation flow works without keychain prompts.
7. Trigger a capture without permission; verify clear permission guidance and no loop spam.
8. For trial states (baseline/day4/expired), verify UI badge/nag text matches expected days/state.
MANUAL
}

usage() {
  cat <<'USAGE'
Usage:
  scripts/public_download_qa.sh [--version <x.y.z>] verify
  scripts/public_download_qa.sh [--version <x.y.z>] install
  scripts/public_download_qa.sh [--version <x.y.z>] clean-room-reset
  scripts/public_download_qa.sh [--version <x.y.z>] launch
  scripts/public_download_qa.sh [--version <x.y.z>] trial-baseline
  scripts/public_download_qa.sh [--version <x.y.z>] trial-day4
  scripts/public_download_qa.sh [--version <x.y.z>] trial-expired
  scripts/public_download_qa.sh [--version <x.y.z>] trial-reset
  scripts/public_download_qa.sh [--version <x.y.z>] all-cli
  scripts/public_download_qa.sh [--version <x.y.z>] manual-checks
USAGE
}

if [[ -z "${COMMAND}" ]]; then
  usage
  exit 1
fi

case "${COMMAND}" in
  verify) verify_public_artifacts ;;
  install) install_public_app ;;
  clean-room-reset) clean_room_reset ;;
  launch) launch_public_app ;;
  trial-baseline) trial_baseline ;;
  trial-day4) trial_day4 ;;
  trial-expired) trial_expired ;;
  trial-reset) trial_reset ;;
  all-cli)
    verify_public_artifacts
    install_public_app
    clean_room_reset
    launch_public_app
    ;;
  manual-checks) print_manual_checks ;;
  *) usage; exit 1 ;;
esac
