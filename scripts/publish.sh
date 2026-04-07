#!/bin/bash
#
# Caloura Full Release Pipeline
# One command: build → notarize → publish manual DMG + Sparkle ZIP
#
# USAGE:
#   ./scripts/publish.sh <version>
#   Example: ./scripts/publish.sh 2.1.4

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 2.1.4"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ZIP_PATH="$BUILD_DIR/Caloura-$VERSION.zip"
DMG_PATH="$BUILD_DIR/Caloura-$VERSION.dmg"
ZIP_NAME="$(basename "$ZIP_PATH")"
DMG_NAME="$(basename "$DMG_PATH")"
MANIFEST_PATH="$BUILD_DIR/release-manifest-$VERSION.json"
SITE_REPO="${SITE_REPO:-$HOME/caloura-site}"
APPCAST_PATH="$SITE_REPO/appcast.xml"
INDEX_PATH="$SITE_REPO/index.html"
APPCAST_URL="https://caloura.app/appcast.xml"

manifest_value() {
    local key="$1"
    python3 - "$MANIFEST_PATH" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

value = manifest.get(sys.argv[2], "")
print(value)
PY
}

validate_appcast_against_manifest() {
    if [ ! -f "$MANIFEST_PATH" ]; then
        echo "Error: Release manifest not found at $MANIFEST_PATH"
        exit 1
    fi

    python3 "$SCRIPT_DIR/validate_appcast_against_manifest.py" \
        --manifest "$MANIFEST_PATH" \
        --file "$APPCAST_PATH"
}

validate_live_appcast_against_manifest() {
    local attempts="${APPCAST_VALIDATION_ATTEMPTS:-12}"
    local delay_seconds="${APPCAST_VALIDATION_DELAY_SECONDS:-10}"
    local attempt=1

    while [[ "$attempt" -le "$attempts" ]]; do
        if python3 "$SCRIPT_DIR/validate_appcast_against_manifest.py" \
            --manifest "$MANIFEST_PATH" \
            --url "$APPCAST_URL"; then
            return 0
        fi

        if [[ "$attempt" -lt "$attempts" ]]; then
            echo "Waiting ${delay_seconds}s for the live appcast to update..."
            sleep "$delay_seconds"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

run_public_download_qa() {
    "$SCRIPT_DIR/public_download_qa.sh" --version "$VERSION" verify
    SIMULATE_QUARANTINE=1 \
        "$SCRIPT_DIR/public_download_qa.sh" --version "$VERSION" install
    REQUIRE_QUARANTINE=1 \
        "$SCRIPT_DIR/public_download_qa.sh" --version "$VERSION" launch
}

find_sign_update() {
    for candidate in \
        "$PROJECT_DIR/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        "$HOME/Applications/Sparkle/bin/sign_update"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    command -v sign_update || true
}

SIGN_UPDATE="$(find_sign_update)"
if [ -z "$SIGN_UPDATE" ]; then
    echo "Error: sign_update not found. Build the project first or install Sparkle."
    exit 1
fi

if [ ! -d "$SITE_REPO/.git" ]; then
    echo "Error: Site repo not found at $SITE_REPO"
    echo "Clone it: git clone git@github.com:Babayosa/caloura-site.git $SITE_REPO"
    exit 1
fi

echo "========================================"
echo "  Caloura v$VERSION — Full Publish"
echo "========================================"
echo ""

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -f "$ZIP_PATH" ] && [ -f "$DMG_PATH" ]; then
    echo "==> Skipping build (SKIP_BUILD=1), using existing artifacts"
else
    echo "==> Step 1/3: Building and notarizing artifacts..."
    "$SCRIPT_DIR/release.sh" "$VERSION"
fi

if [ ! -f "$ZIP_PATH" ]; then
    echo "Error: Expected Sparkle ZIP not found at $ZIP_PATH"
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: Expected manual-download DMG not found at $DMG_PATH"
    exit 1
fi

echo ""
echo "==> Step 2/3: Publishing artifacts to caloura.app..."

git -C "$SITE_REPO" pull --ff-only

mkdir -p "$SITE_REPO/releases"
cp "$ZIP_PATH" "$SITE_REPO/releases/$ZIP_NAME"
cp "$DMG_PATH" "$SITE_REPO/releases/$DMG_NAME"

ZIP_LENGTH="$(stat -f%z "$SITE_REPO/releases/$ZIP_NAME")"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$SITE_REPO/releases/$ZIP_NAME")"
SIGNATURE="$(echo "$SIGN_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | cut -d'"' -f2)"

if [ -z "$SIGNATURE" ]; then
    echo "Error: Could not extract Sparkle signature"
    exit 1
fi

BUILD_NUMBER="$(manifest_value build_number)"
MINIMUM_SYSTEM_VERSION="$(manifest_value minimum_system_version)"
PUBDATE="$(date -R)"
TMPITEM="$(mktemp)"

cat > "$TMPITEM" <<XMLEOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>What's New</h2>
        <ul>
          <li>See release notes</li>
        </ul>
      ]]></description>
      <enclosure
        url="https://caloura.app/releases/$ZIP_NAME"
        type="application/octet-stream"
        sparkle:version="$BUILD_NUMBER"
        sparkle:shortVersionString="$VERSION"
        sparkle:minimumSystemVersion="$MINIMUM_SYSTEM_VERSION"
        sparkle:edSignature="$SIGNATURE"
        length="$ZIP_LENGTH"
      />
    </item>
XMLEOF

sed -i '' "/<language>en<\/language>/r $TMPITEM" "$APPCAST_PATH"
rm -f "$TMPITEM"

sed -i '' -E "s#releases/Caloura-[0-9][0-9.]*(\.zip|\.dmg)#releases/$DMG_NAME#g" "$INDEX_PATH"

validate_appcast_against_manifest

echo ""
echo "==> Step 3/3: Committing and pushing site changes..."
git -C "$SITE_REPO" add "releases/$ZIP_NAME" "releases/$DMG_NAME" appcast.xml index.html
git -C "$SITE_REPO" commit -m "Release v$VERSION"
git -C "$SITE_REPO" push

echo ""
echo "==> Validating live appcast after publish..."
if ! validate_live_appcast_against_manifest; then
    echo "Error: Live appcast validation failed after publish."
    exit 1
fi

if [[ "${SKIP_PUBLIC_DOWNLOAD_QA:-0}" != "1" ]]; then
    echo ""
    echo "==> Running public-download QA against the live release..."
    run_public_download_qa
fi

echo ""
echo "========================================"
echo "  v$VERSION is live!"
echo "========================================"
echo ""
echo "  Website:           https://caloura.app"
echo "  Manual download:   https://caloura.app/releases/$DMG_NAME"
echo "  Sparkle artifact:  https://caloura.app/releases/$ZIP_NAME"
echo "  Appcast:           https://caloura.app/appcast.xml"
echo ""
echo "  GitHub Pages may take 1-2 minutes to propagate."
echo "  Existing users will continue updating through Sparkle."
echo ""
