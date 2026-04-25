#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Caloura"
BUNDLE_ID="com.caloura.app"
APPCAST_URL="https://caloura.app/appcast.xml"
INSTALL_PATH="/Applications/Caloura.app"
VERSION="${CALOURA_VERSION:-}"
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

DMG_DOWNLOAD_URL="https://caloura.app/releases/Caloura-${VERSION}.dmg"
DMG_PATH="${TMPDIR:-/tmp}/Caloura-${VERSION}.dmg"
DMG_MOUNT="${TMPDIR:-/tmp}/Caloura-public-${VERSION}-mount"

print_header() {
  echo ""
  echo "==> $1"
}

require_version() {
  local command="$1"
  if [[ -z "${VERSION}" ]]; then
    echo "ERROR: --version is required for '${command}'"
    echo ""
    usage
    exit 1
  fi
}

detach_dmg_if_needed() {
  if mount | grep -q "on ${DMG_MOUNT} "; then
    hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
  fi
}

print_storage_snapshot() {
  local app_support="$HOME/Library/Application Support/Caloura"
  local history_path="$app_support/history.enc"
  local security_dir="$app_support/security"
  local key_path="$security_dir/history.key"

  local history_perm=""
  local security_perm=""
  local key_perm=""

  history_perm="$(stat -f '%OLp' "$history_path" 2>/dev/null || true)"
  security_perm="$(stat -f '%OLp' "$security_dir" 2>/dev/null || true)"
  key_perm="$(stat -f '%OLp' "$key_path" 2>/dev/null || true)"

  echo "Storage snapshot:"
  echo "  history.enc: $([[ -f "$history_path" ]] && echo present || echo missing) perm=${history_perm:-n/a}"
  echo "  security/:   $([[ -d "$security_dir" ]] && echo present || echo missing) perm=${security_perm:-n/a}"
  echo "  history.key: $([[ -f "$key_path" ]] && echo present || echo missing) perm=${key_perm:-n/a}"
}

ensure_app_not_running() {
  local existing_pids
  existing_pids="$(pgrep -x "$APP_NAME" || true)"
  if [[ -z "$existing_pids" ]]; then
    return
  fi

  echo "Stopping existing $APP_NAME processes before launch QA..."
  pkill -x "$APP_NAME" || true
  sleep 2

  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "ERROR: Existing $APP_NAME process is still running; launch QA requires a clean process start."
    pgrep -fl "$APP_NAME" || true
    exit 1
  fi
}

verify_public_artifacts() {
  require_version "verify"
  print_header "Phase 1: Verify Public Artifact + Appcast"
  echo "Version under test: ${VERSION}"
  echo "Manual download HEAD:"
  curl -fI "$DMG_DOWNLOAD_URL"

  local sparkle_url
  sparkle_url="$(sparkle_artifact_url_for_version "$VERSION")"
  echo ""
  echo "Sparkle artifact HEAD: $sparkle_url"
  curl -fI "$sparkle_url"

  echo ""
  echo "Appcast matches (version + artifact URL + sparkle versions):"
  curl -fsSL "$APPCAST_URL" | grep -n "Version ${VERSION}\\|$(basename "$sparkle_url")\\|sparkle:version\\|sparkle:shortVersionString\\|sparkle:minimumSystemVersion"
}

sparkle_artifact_url_for_version() {
  local version="$1"
  python3 - "$APPCAST_URL" "$version" <<'PY'
import sys
import urllib.request
import xml.etree.ElementTree as ET

sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
appcast_url = sys.argv[1]
target_version = sys.argv[2]

with urllib.request.urlopen(appcast_url) as response:
    root = ET.fromstring(response.read())

channel = root.find("channel")
if channel is None:
    raise SystemExit("Appcast missing <channel>")

for item in channel.findall("item"):
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    short_version = enclosure.attrib.get(f"{{{sparkle_ns}}}shortVersionString", "")
    if short_version == target_version:
        url = enclosure.attrib.get("url", "")
        if not url:
            raise SystemExit(f"Appcast item for {target_version} has no enclosure URL")
        print(url)
        raise SystemExit(0)

raise SystemExit(f"Appcast has no item for version {target_version}")
PY
}

install_public_app() {
  require_version "install"
  print_header "Download DMG + Install Public App"
  rm -f "$DMG_PATH"
  rm -rf "$DMG_MOUNT"
  mkdir -p "$DMG_MOUNT"

  curl -L "$DMG_DOWNLOAD_URL" -o "$DMG_PATH"

  local dmg_size
  dmg_size=$(stat -f '%z' "$DMG_PATH" 2>/dev/null || echo "0")
  if [[ "$dmg_size" -lt 1000 ]]; then
    echo "ERROR: Downloaded DMG is suspiciously small (${dmg_size} bytes)"
    exit 1
  fi
  echo "  DMG size: ${dmg_size} bytes"
  echo "  SHA256: $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

  hdiutil attach "$DMG_PATH" -nobrowse -mountpoint "$DMG_MOUNT" >/dev/null

  if [[ ! -d "$DMG_MOUNT/Caloura.app" ]]; then
    echo "ERROR: Expected app not found in DMG: $DMG_MOUNT/Caloura.app"
    detach_dmg_if_needed
    exit 1
  fi

  if [[ ! -L "$DMG_MOUNT/Applications" ]]; then
    echo "ERROR: Expected Applications symlink not found in DMG"
    detach_dmg_if_needed
    exit 1
  fi

  if ! codesign --verify --deep --strict "$DMG_MOUNT/Caloura.app" 2>/dev/null; then
    echo "WARNING: Code signature verification failed on mounted app"
  else
    echo "  Code signature: valid"
  fi

  rm -rf "$INSTALL_PATH"
  ditto "$DMG_MOUNT/Caloura.app" "$INSTALL_PATH"
  strip_quarantine="${STRIP_QUARANTINE:-0}"
  if [[ "${KEEP_QUARANTINE:-1}" = "0" ]]; then
    strip_quarantine=1
  fi

  if [[ "$strip_quarantine" = "1" ]]; then
    xattr -dr com.apple.quarantine "$INSTALL_PATH" || true
    echo "STRIP_QUARANTINE=1 set: removed quarantine attribute for local-only QA."
  else
    echo "Quarantine preserved by default for Gatekeeper validation."
    if [[ "${SIMULATE_QUARANTINE:-0}" = "1" ]] && \
       ! xattr -p com.apple.quarantine "$INSTALL_PATH" >/dev/null 2>&1; then
      quarantine_stamp=$(printf '%x' "$(date +%s)")
      quarantine_value="0081;${quarantine_stamp};CalouraQA;$(uuidgen)"
      xattr -w com.apple.quarantine "$quarantine_value" "$INSTALL_PATH"
      echo "SIMULATE_QUARANTINE=1 set: applied quarantine attribute for Gatekeeper QA."
    fi
  fi

  detach_dmg_if_needed
  rm -rf "$DMG_MOUNT"

  echo "Installed: $INSTALL_PATH"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true
}

clean_room_reset() {
  print_header "Phase 2: Clean-Room Reset"
  require_version "clean-room-reset"
  pkill -x "$APP_NAME" || true
  defaults delete "$BUNDLE_ID" || true
  tccutil reset ScreenCapture "$BUNDLE_ID" || true

  rm -f "$HOME/Library/Application Support/Caloura/history.enc" || true
  rm -rf "$HOME/Library/Application Support/Caloura/security" || true

  security delete-generic-password -s "$BUNDLE_ID" -a licenseKey >/dev/null 2>&1 || true
  security delete-generic-password -s "$BUNDLE_ID" -a screenshotHistoryKey >/dev/null 2>&1 || true

  print_storage_snapshot
}

launch_public_app() {
  print_header "Launch Public App"
  require_version "launch"
  if [ ! -d "$INSTALL_PATH" ]; then
    echo "ERROR: $INSTALL_PATH not found. Run install step first."
    exit 1
  fi

  if [[ "${REQUIRE_QUARANTINE:-0}" = "1" ]]; then
    if ! xattr -p com.apple.quarantine "$INSTALL_PATH" >/dev/null 2>&1; then
      echo "ERROR: Gatekeeper QA requires a quarantine attribute on $INSTALL_PATH"
      exit 1
    fi
    spctl -a -vv "$INSTALL_PATH"
  fi

  ensure_app_not_running
  open -a "$INSTALL_PATH"
  sleep 3

  local launched_pids
  launched_pids="$(pgrep -x "$APP_NAME" || true)"
  echo "Running processes:"
  if [[ -z "$launched_pids" ]]; then
    echo "ERROR: $APP_NAME did not remain running after launch"
    exit 1
  fi
  pgrep -fl "$APP_NAME"

  print_storage_snapshot
}

trial_baseline() {
  print_header "Phase 5: Trial Baseline"
  require_version "trial-baseline"
  if [ ! -d "$INSTALL_PATH" ]; then
    echo "ERROR: $INSTALL_PATH not found. Run install step first."
    exit 1
  fi
  defaults delete "$BUNDLE_ID" firstLaunchDate || true
  defaults write "$BUNDLE_ID" isLicenseActivated -bool false
  security delete-generic-password -s "$BUNDLE_ID" -a licenseKey >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" || true
  open -a "$INSTALL_PATH"
  sleep 2

  echo "firstLaunchDate after launch:"
  defaults read "$BUNDLE_ID" firstLaunchDate || true
  echo "isLicenseActivated:"
  defaults read "$BUNDLE_ID" isLicenseActivated || true
}

trial_day4() {
  local launch_date
  launch_date="$(date -u -v-3d '+%Y-%m-%d 10:00:00 +0000')"
  print_header "Phase 5: Simulate Day 4 (${launch_date%% *})"
  require_version "trial-day4"
  if [ ! -d "$INSTALL_PATH" ]; then
    echo "ERROR: $INSTALL_PATH not found. Run install step first."
    exit 1
  fi
  defaults write "$BUNDLE_ID" firstLaunchDate -date "$launch_date"
  defaults write "$BUNDLE_ID" isLicenseActivated -bool false
  pkill -x "$APP_NAME" || true
  open -a "$INSTALL_PATH"
  sleep 2

  echo "Configured firstLaunchDate:"
  defaults read "$BUNDLE_ID" firstLaunchDate || true
}

trial_expired() {
  local launch_date
  launch_date="$(date -u -v-8d '+%Y-%m-%d 10:00:00 +0000')"
  print_header "Phase 5: Simulate Expired Trial (${launch_date%% *})"
  require_version "trial-expired"
  if [ ! -d "$INSTALL_PATH" ]; then
    echo "ERROR: $INSTALL_PATH not found. Run install step first."
    exit 1
  fi
  defaults write "$BUNDLE_ID" firstLaunchDate -date "$launch_date"
  defaults write "$BUNDLE_ID" isLicenseActivated -bool false
  pkill -x "$APP_NAME" || true
  open -a "$INSTALL_PATH"
  sleep 2

  echo "Configured firstLaunchDate:"
  defaults read "$BUNDLE_ID" firstLaunchDate || true
}

trial_reset() {
  print_header "Phase 5: Reset Trial Overrides"
  require_version "trial-reset"
  if [ ! -d "$INSTALL_PATH" ]; then
    echo "ERROR: $INSTALL_PATH not found. Run install step first."
    exit 1
  fi
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
1. Open the downloaded DMG and verify it presents `Caloura.app` alongside an `Applications` shortcut.
2. Drag Caloura into `/Applications` and launch the installed copy only.
3. On first launch, verify onboarding starts on "Take your first screenshot" instead of a permission wizard.
4. If Screen Recording is already enabled, trigger the first capture and verify Caloura starts capture without switching into repair UI first.
5. If Screen Recording is missing, trigger the first capture from the onboarding CTA and verify the app waits for the System Settings return, re-checks automatically, and resumes the pending capture on success.
6. If Screen Recording was just granted, verify the installed app recognizes it without falling back to repair UI unless a real capture validation still fails.
7. Verify scroll capture requests Accessibility only when Scroll Capture is used.
8. Verify no keychain password dialog appears at startup, onboarding, capture, License, or History.
9. After a few captures, open History and confirm encrypted-at-rest storage exists at:
   - ~/Library/Application Support/Caloura/history.enc (expected perm 600)
   - ~/Library/Application Support/Caloura/security/history.key (expected perm 600; parent dir 700)
10. Verify the manual download is the DMG while Sparkle still updates from the ZIP/appcast path.
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

Notes:
  - Quarantine is preserved by default. Set STRIP_QUARANTINE=1 to remove it for local-only QA.
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
    require_version "all-cli"
    verify_public_artifacts
    install_public_app
    clean_room_reset
    launch_public_app
    ;;
  manual-checks) print_manual_checks ;;
  *) usage; exit 1 ;;
esac
