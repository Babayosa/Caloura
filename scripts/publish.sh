#!/bin/bash
#
# Caloura Full Release Pipeline
# One command: build → notarize → sign appcast → publish to GitHub Pages
#
# USAGE:
#   ./scripts/publish.sh <version>
#   Example: ./scripts/publish.sh 1.0.9
#
# PREREQUISITES:
#   - Developer ID certificate installed in Keychain
#   - Notarization credentials stored (see release.sh header)
#   - Sparkle EdDSA signing key in Keychain (via generate_keys)
#   - caloura-site repo cloned (default: ~/caloura-site)
#
# CONFIGURATION (environment variables):
#   SITE_REPO    Path to caloura-site repo (default: ~/caloura-site)
#   SKIP_BUILD   Set to 1 to skip build and use existing zip in build/
#

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.0.9"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ZIP_PATH="$BUILD_DIR/Caloura-$VERSION.zip"
MANIFEST_PATH="$BUILD_DIR/release-manifest-$VERSION.json"
SITE_REPO="${SITE_REPO:-$HOME/caloura-site}"

read_plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

validate_appcast_against_manifest() {
    local appcast="$SITE_REPO/appcast.xml"
    if [ ! -f "$MANIFEST_PATH" ]; then
        echo "Error: Release manifest not found at $MANIFEST_PATH"
        exit 1
    fi

    python3 "$SCRIPT_DIR/validate_appcast_against_manifest.py" \
        --manifest "$MANIFEST_PATH" \
        --file "$appcast"
}

# Locate sign_update from Sparkle SPM artifacts
SIGN_UPDATE=""
for candidate in \
    "$PROJECT_DIR/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$HOME/Applications/Sparkle/bin/sign_update"; do
    if [ -f "$candidate" ]; then
        SIGN_UPDATE="$candidate"
        break
    fi
done

if [ -z "$SIGN_UPDATE" ] && ! command -v sign_update &> /dev/null; then
    echo "Error: sign_update not found. Build the project first or install Sparkle."
    exit 1
fi

# If we found a local binary, add its directory to PATH
if [ -n "$SIGN_UPDATE" ]; then
    export PATH="$(dirname "$SIGN_UPDATE"):$PATH"
fi

# Verify site repo exists
if [ ! -d "$SITE_REPO/.git" ]; then
    echo "Error: Site repo not found at $SITE_REPO"
    echo "Clone it: git clone git@github.com:Babayosa/caloura-site.git $SITE_REPO"
    exit 1
fi

echo "========================================"
echo "  Caloura v$VERSION — Full Publish"
echo "========================================"
echo ""

# ── Step 1: Build + Notarize ──────────────────────────────────────
if [ "${SKIP_BUILD:-0}" = "1" ] && [ -f "$ZIP_PATH" ]; then
    echo "==> Skipping build (SKIP_BUILD=1), using existing $ZIP_PATH"
else
    echo "==> Step 1/3: Building and notarizing..."
    "$SCRIPT_DIR/release.sh" "$VERSION"
fi

if [ ! -f "$ZIP_PATH" ]; then
    echo "Error: Expected zip not found at $ZIP_PATH"
    exit 1
fi

echo ""
echo "==> Step 2/3: Publishing to caloura.app..."

# ── Step 2: Publish to GitHub Pages ───────────────────────────────
# Pull latest site repo to avoid push conflicts
git -C "$SITE_REPO" pull --ff-only

# Run the site's release script
"$SITE_REPO/release.sh" "$ZIP_PATH"
validate_appcast_against_manifest

# ── Step 3: Summary ──────────────────────────────────────────────
echo ""
echo "========================================"
echo "  v$VERSION is live!"
echo "========================================"
echo ""
echo "  Website:  https://caloura.app"
echo "  Download: https://caloura.app/releases/Caloura-$VERSION.zip"
echo "  Appcast:  https://caloura.app/appcast.xml"
echo ""
echo "  GitHub Pages may take 1-2 minutes to propagate."
echo "  Existing users will see the update via Sparkle."
echo ""
