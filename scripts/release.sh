#!/bin/bash
#
# Caloura Release Script
# Builds, signs, notarizes, and packages Caloura for Gumroad distribution.
#
# FIRST-TIME SETUP (one-time steps before your first release):
#
# 1. Developer ID certificate
#    Go to developer.apple.com -> Certificates, Identifiers & Profiles
#    Create a "Developer ID Application" certificate and install it in Keychain.
#
# 2. Notarization credentials
#    Create an app-specific password at appleid.apple.com -> Sign-In and Security.
#    Then store it in your keychain:
#
#      xcrun notarytool store-credentials "Caloura-Notarize" \
#          --apple-id "your@email.com" \
#          --team-id "NG4ML6Q47T" \
#          --password "<app-specific-password>"
#
# 3. Sparkle EdDSA signing key (for auto-updates)
#    Download Sparkle from https://github.com/sparkle-project/Sparkle/releases
#    Extract and run:
#
#      ./bin/generate_keys
#
#    This stores the private key in Keychain and prints the public key.
#    Add the public key to project.yml -> info -> properties -> SUPublicEDKey
#
# 4. Appcast hosting (for Sparkle auto-updates)
#    Create a GitHub repo (e.g. github.com/YOU/caloura-appcast)
#    Enable GitHub Pages on the main branch.
#    Add the URL to project.yml -> info -> properties:
#
#      SUFeedURL: "https://YOU.github.io/caloura-appcast/appcast.xml"
#
#    After each release, run generate_appcast to update it (see step at end).
#
# USAGE:
#   ./scripts/release.sh <version>
#   Example: ./scripts/release.sh 1.0.0
#

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.0.0"
    exit 1
fi

APP_NAME="Caloura"
SCHEME="Caloura"
TEAM_ID="NG4ML6Q47T"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"

normalize_version() {
    local raw="$1"
    raw="${raw#refs/tags/}"
    raw="${raw#v}"
    echo "$raw"
}

fail_release() {
    echo "ERROR: $1" >&2
    exit 1
}

check_release_tag_alignment() {
    local expected_version
    expected_version="$(normalize_version "$VERSION")"
    local release_tag="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"

    if [ -n "$release_tag" ]; then
        local normalized_tag
        normalized_tag="$(normalize_version "$release_tag")"
        if [ "$normalized_tag" != "$expected_version" ]; then
            fail_release "Release tag '$release_tag' does not match version '$VERSION'."
        fi
        echo "==> Release tag check passed ($release_tag)"
        return
    fi

    if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local head_tag=""
        head_tag="$(git -C "$PROJECT_DIR" describe --tags --exact-match 2>/dev/null || true)"
        if [ -n "$head_tag" ]; then
            local normalized_head_tag
            normalized_head_tag="$(normalize_version "$head_tag")"
            if [ "$normalized_head_tag" != "$expected_version" ]; then
                fail_release "HEAD tag '$head_tag' does not match version '$VERSION'."
            fi
            echo "==> Git HEAD tag check passed ($head_tag)"
            return
        fi
    fi

    echo "==> No release tag provided and HEAD is not tagged; skipping tag parity check"
    echo "    (set RELEASE_TAG=v$VERSION in CI to enforce tag/version matching)."
}

read_plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

check_bundle_version_matches_release() {
    local plist_path="$1"
    local source_label="$2"
    local bundle_version
    bundle_version="$(read_plist_value "$plist_path" "CFBundleShortVersionString")"

    if [ -z "$bundle_version" ]; then
        fail_release "Missing CFBundleShortVersionString in $source_label ($plist_path)."
    fi

    if [ "$bundle_version" != "$VERSION" ]; then
        fail_release "Version mismatch in $source_label: bundle=$bundle_version release=$VERSION."
    fi

    echo "==> $source_label version check passed (CFBundleShortVersionString=$bundle_version)"
}

check_version_placeholders() {
    local plist_path="$PROJECT_DIR/Caloura/Resources/Info.plist"
    local marketing_value
    local build_value
    marketing_value="$(read_plist_value "$plist_path" "CFBundleShortVersionString")"
    build_value="$(read_plist_value "$plist_path" "CFBundleVersion")"

    if [ "$marketing_value" != '$(MARKETING_VERSION)' ]; then
        fail_release "Info.plist CFBundleShortVersionString must be \$(MARKETING_VERSION) for release consistency."
    fi
    if [ "$build_value" != '$(CURRENT_PROJECT_VERSION)' ]; then
        fail_release "Info.plist CFBundleVersion must be \$(CURRENT_PROJECT_VERSION) for release consistency."
    fi
}

echo "==> Building $APP_NAME v$VERSION"
echo ""

# Guard against accidental tag/version mismatch before packaging.
check_release_tag_alignment
check_version_placeholders

if [ "${RELEASE_GUARD_ONLY:-0}" = "1" ]; then
    echo "==> Guard-only mode: release tag and version placeholder checks passed."
    exit 0
fi

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Regenerate Xcode project
echo "==> Regenerating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

# Archive
echo "==> Archiving (Release configuration)..."
xcodebuild archive \
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M%S)" \
    -quiet

echo "    Archive: $ARCHIVE_PATH"

# Export with Developer ID signing
echo "==> Exporting with Developer ID signing..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
    -quiet

echo "    App: $APP_PATH"

# Guard: fail release if bundled marketing version drifted from filename/tag version.
check_bundle_version_matches_release "$APP_PATH/Contents/Info.plist" "Exported app"

# Verify code signature
echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature valid"

# Create zip for notarization (--sequesterRsrc preserves resource forks for Gatekeeper)
echo "==> Creating zip for notarization..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# Notarize
echo "==> Submitting for notarization (this may take a few minutes)..."
if ! xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "Caloura-Notarize" \
    --wait; then
    fail_release "Notarization failed. Run 'xcrun notarytool log' for details."
fi

# Staple the notarization ticket to the app
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

# Re-create zip with the stapled app (--sequesterRsrc preserves resource forks for Gatekeeper)
rm "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# Guard: verify final zipped artifact still carries the expected app version.
ZIP_VERIFY_DIR="$(mktemp -d "$BUILD_DIR/zip-verify.XXXXXX")"
cleanup_zip_verify() {
    rm -rf "$ZIP_VERIFY_DIR"
}
trap cleanup_zip_verify EXIT
ditto -x -k "$ZIP_PATH" "$ZIP_VERIFY_DIR"
check_bundle_version_matches_release "$ZIP_VERIFY_DIR/$APP_NAME.app/Contents/Info.plist" "Final zip artifact"

# Summary
echo ""
echo "============================================"
echo "  Release build complete!"
echo "============================================"
echo "  Version: $VERSION"
echo "  File:    $ZIP_PATH"
echo "  Size:    $(du -h "$ZIP_PATH" | cut -f1)"
echo ""
echo "Next steps:"
echo "  • To publish now:  ./scripts/publish.sh $VERSION"
echo "    (or re-run with SKIP_BUILD=1 to skip the build step)"
echo "  • Upload $ZIP_PATH to Gumroad manually"
echo ""
