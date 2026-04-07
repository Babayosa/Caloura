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
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
MANIFEST_PATH="$BUILD_DIR/release-manifest-$VERSION.json"
NOTARY_PROFILE="${NOTARY_PROFILE:-Caloura-Notarize}"
BUILD_SETTINGS_CACHE="$BUILD_DIR/release-build-settings.txt"
BUILD_DESTINATION="${BUILD_DESTINATION:-platform=macOS,arch=arm64}"
DMG_VOLUME_NAME="$APP_NAME"
DMG_BACKGROUND_SOURCE="$PROJECT_DIR/scripts/assets/dmg-neutral-background.png"
DMG_BACKGROUND_NAME="install-background.png"

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

build_setting_value() {
    local key="$1"
    local env_value="${!key:-}"
    if [ -n "$env_value" ]; then
        echo "$env_value"
        return
    fi

    if [ ! -f "$BUILD_SETTINGS_CACHE" ]; then
        mkdir -p "$BUILD_DIR"
        xcodebuild -showBuildSettings \
            -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination "$BUILD_DESTINATION" \
            > "$BUILD_SETTINGS_CACHE"
    fi

    local value
    value="$(awk -F' = ' -v needle="$key" '$1 ~ ("^[[:space:]]*" needle "$") {print $2; exit}' "$BUILD_SETTINGS_CACHE")"
    echo "$value" | sed 's/[[:space:]]*$//'
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

check_minimum_system_version_alignment() {
    local plist_path="$PROJECT_DIR/Caloura/Resources/Info.plist"
    local plist_min
    local project_min

    plist_min="$(read_plist_value "$plist_path" "LSMinimumSystemVersion")"
    project_min="$(awk -F'"' '/deploymentTarget:/{found=1} found && /macOS:/{print $2; exit}' "$PROJECT_DIR/project.yml")"

    if [ -z "$plist_min" ]; then
        fail_release "Missing LSMinimumSystemVersion in $plist_path."
    fi

    if [ -z "$project_min" ]; then
        fail_release "Missing deploymentTarget.macOS in project.yml."
    fi

    if [ "$plist_min" != "$project_min" ]; then
        fail_release "Minimum macOS version mismatch: Info.plist=$plist_min project.yml=$project_min."
    fi

    echo "==> Minimum macOS version check passed (LSMinimumSystemVersion=$plist_min)"
}

check_sparkle_release_metadata() {
    local plist_path="$PROJECT_DIR/Caloura/Resources/Info.plist"
    local feed_url
    local public_key

    feed_url="$(read_plist_value "$plist_path" "SUFeedURL")"
    public_key="$(read_plist_value "$plist_path" "SUPublicEDKey")"

    if [ -z "$feed_url" ]; then
        fail_release "Missing SUFeedURL in $plist_path."
    fi

    if [ -z "$public_key" ]; then
        fail_release "Missing SUPublicEDKey in $plist_path."
    fi

    echo "==> Sparkle metadata check passed"
}

check_release_license_configuration() {
    local requires_signed
    local entitlement_url
    local entitlement_public_key

    requires_signed="$(build_setting_value "CALOURA_REQUIRE_SIGNED_ENTITLEMENT")"
    entitlement_url="$(build_setting_value "CALOURA_LICENSE_ENTITLEMENT_URL")"
    entitlement_public_key="$(build_setting_value "CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY")"

    if [ "$requires_signed" != "YES" ]; then
        fail_release "Release configuration must set CALOURA_REQUIRE_SIGNED_ENTITLEMENT=YES."
    fi

    if [ -z "$entitlement_url" ]; then
        fail_release "Release configuration is missing CALOURA_LICENSE_ENTITLEMENT_URL."
    fi

    if [ -z "$entitlement_public_key" ]; then
        fail_release "Release configuration is missing CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY."
    fi

    echo "==> Release license configuration check passed"
}

verify_release_environment() {
    local feed_url
    feed_url="$(read_plist_value "$PROJECT_DIR/Caloura/Resources/Info.plist" "SUFeedURL")"

    if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
        fail_release "Developer ID Application signing identity not found in Keychain."
    fi

    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        fail_release "Notarization profile '$NOTARY_PROFILE' is missing or unusable."
    fi

    if ! curl -fsSIL "$feed_url" >/dev/null; then
        fail_release "Sparkle feed URL is unreachable: $feed_url"
    fi

    echo "==> Release environment check passed"
}

verify_signed_identity() {
    local app_path="$1"
    local signature_details
    signature_details="$(codesign -dvv "$app_path" 2>&1)"

    if ! grep -q "TeamIdentifier=$TEAM_ID" <<<"$signature_details"; then
        fail_release "Signed app team identifier does not match expected Team ID $TEAM_ID."
    fi

    if ! grep -q "Authority=Developer ID Application" <<<"$signature_details"; then
        fail_release "Signed app is not using a Developer ID Application certificate."
    fi

    echo "    Signing identity matches Team ID $TEAM_ID"
}

verify_gatekeeper_and_notarization() {
    local app_path="$1"
    local spctl_output
    spctl_output="$(mktemp)"

    if ! spctl -a -vv "$app_path" >"$spctl_output" 2>&1; then
        cat "$spctl_output"
        rm -f "$spctl_output"
        fail_release "Gatekeeper assessment failed."
    fi

    if ! grep -q "accepted" "$spctl_output"; then
        cat "$spctl_output"
        rm -f "$spctl_output"
        fail_release "Gatekeeper did not accept the app."
    fi

    rm -f "$spctl_output"

    xcrun stapler validate "$app_path"
    echo "    Gatekeeper and stapler validation passed"
}

create_branded_dmg() {
    local staging_dir="$BUILD_DIR/dmg-root"
    local mount_point="$BUILD_DIR/dmg-mount"
    local rw_dmg="$BUILD_DIR/$APP_NAME-$VERSION-rw.dmg"

    if [ ! -f "$DMG_BACKGROUND_SOURCE" ]; then
        fail_release "Missing DMG background asset at $DMG_BACKGROUND_SOURCE."
    fi

    # Detach any leftover volume from a previous failed run
    hdiutil detach "/Volumes/$DMG_VOLUME_NAME" -force 2>/dev/null || true

    rm -rf "$staging_dir" "$mount_point" "$rw_dmg" "$DMG_PATH"
    mkdir -p "$staging_dir/.background" "$mount_point"

    cp -R "$APP_PATH" "$staging_dir/$APP_NAME.app"
    ln -s /Applications "$staging_dir/Applications"
    cp "$DMG_BACKGROUND_SOURCE" "$staging_dir/.background/$DMG_BACKGROUND_NAME"

    hdiutil create -quiet \
        -fs HFS+ \
        -srcfolder "$staging_dir" \
        -volname "$DMG_VOLUME_NAME" \
        -format UDRW \
        "$rw_dmg"

    hdiutil attach -quiet \
        -readwrite \
        -noverify \
        -noautoopen \
        "$rw_dmg"

    # Finder needs the volume at /Volumes/<name> to address it by disk name
    mount_point="/Volumes/$DMG_VOLUME_NAME"
    sleep 1

    osascript >/dev/null <<EOF
tell application "Finder"
    tell disk "$DMG_VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 160, 760, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:$DMG_BACKGROUND_NAME"
        set position of item "$APP_NAME.app" of container window to {160, 180}
        set position of item "Applications" of container window to {400, 180}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF

    sync
    hdiutil detach -quiet "$mount_point"
    hdiutil convert -quiet "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"

    rm -rf "$staging_dir" "$mount_point" "$rw_dmg"
}

sign_and_notarize_dmg() {
    codesign --force --sign "Developer ID Application" --timestamp "$DMG_PATH"
    if ! xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
        fail_release "DMG notarization failed. Run 'xcrun notarytool log' for details."
    fi
    xcrun stapler staple "$DMG_PATH"
}

verify_dmg_artifact() {
    local mount_point="$BUILD_DIR/dmg-verify"
    rm -rf "$mount_point"
    mkdir -p "$mount_point"

    # spctl -t open is unreliable for DMGs from CLI ("Insufficient Context").
    # stapler validate is the authoritative check for notarization.
    if ! xcrun stapler validate "$DMG_PATH" 2>/dev/null; then
        fail_release "DMG notarization staple validation failed."
    fi

    hdiutil attach -quiet \
        -readonly \
        -noverify \
        -noautoopen \
        "$DMG_PATH" \
        -mountpoint "$mount_point"

    check_bundle_version_matches_release "$mount_point/$APP_NAME.app/Contents/Info.plist" "Final dmg artifact"

    if [ ! -L "$mount_point/Applications" ]; then
        hdiutil detach -quiet "$mount_point" || true
        fail_release "DMG is missing the /Applications symlink."
    fi

    hdiutil detach -quiet "$mount_point"
    rm -rf "$mount_point"
    echo "    DMG validation passed"
}

generate_release_manifest() {
    local app_path="$1"
    local sparkle_artifact_path="$2"
    local manual_artifact_path="$3"

    python3 "$SCRIPT_DIR/release_manifest.py" \
        --app "$app_path" \
        --artifact "$sparkle_artifact_path" \
        --sparkle-artifact "$sparkle_artifact_path" \
        --manual-artifact "$manual_artifact_path" \
        --output "$MANIFEST_PATH" >/dev/null

    echo "==> Release manifest generated at $MANIFEST_PATH"
}

generate_source_release_manifest() {
    local plist_path="$PROJECT_DIR/Caloura/Resources/Info.plist"
    local bundle_identifier
    local marketing_version
    local build_number
    local minimum_system_version
    local release_channel
    local requires_signed
    local entitlement_url
    local entitlement_public_key

    bundle_identifier="$(build_setting_value "PRODUCT_BUNDLE_IDENTIFIER")"
    marketing_version="$(build_setting_value "MARKETING_VERSION")"
    # Use the requested release version as the canonical build number.
    build_number="$VERSION"
    minimum_system_version="$(build_setting_value "MACOSX_DEPLOYMENT_TARGET")"
    release_channel="$(build_setting_value "CALOURA_RELEASE_CHANNEL")"
    requires_signed="$(build_setting_value "CALOURA_REQUIRE_SIGNED_ENTITLEMENT")"
    entitlement_url="$(build_setting_value "CALOURA_LICENSE_ENTITLEMENT_URL")"
    entitlement_public_key="$(build_setting_value "CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY")"

    python3 "$SCRIPT_DIR/release_manifest.py" \
        --info-plist "$plist_path" \
        --output "$MANIFEST_PATH" \
        --bundle-identifier "$bundle_identifier" \
        --marketing-version "$marketing_version" \
        --build-number "$build_number" \
        --minimum-system-version "$minimum_system_version" \
        --release-channel "$release_channel" \
        --requires-signed-entitlement "$requires_signed" \
        --entitlement-service-url "$entitlement_url" \
        --entitlement-public-key-configured "$([ -n "$entitlement_public_key" ] && echo true || echo false)" \
        >/dev/null

    echo "==> Source release manifest generated at $MANIFEST_PATH"
}

echo "==> Building $APP_NAME v$VERSION"
echo ""

# Guard against accidental tag/version mismatch before packaging.
check_release_tag_alignment
check_version_placeholders
check_minimum_system_version_alignment
check_sparkle_release_metadata
check_release_license_configuration
verify_release_environment

if [ "${RELEASE_GUARD_ONLY:-0}" = "1" ]; then
    generate_source_release_manifest
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
ARCHIVE_OVERRIDES=(
    MARKETING_VERSION="$VERSION"
    # Keep the release build number stable for a given release version.
    CURRENT_PROJECT_VERSION="$VERSION"
)
[ -n "${CALOURA_REQUIRE_SIGNED_ENTITLEMENT:-}" ] && ARCHIVE_OVERRIDES+=(CALOURA_REQUIRE_SIGNED_ENTITLEMENT="$CALOURA_REQUIRE_SIGNED_ENTITLEMENT")
[ -n "${CALOURA_LICENSE_ENTITLEMENT_URL:-}" ] && ARCHIVE_OVERRIDES+=(CALOURA_LICENSE_ENTITLEMENT_URL="$CALOURA_LICENSE_ENTITLEMENT_URL")
[ -n "${CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY:-}" ] && ARCHIVE_OVERRIDES+=(CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY="$CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY")
xcodebuild archive \
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'platform=macOS,arch=arm64' \
    "${ARCHIVE_OVERRIDES[@]}" \
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
verify_signed_identity "$APP_PATH"
echo "    Signature valid"

# Create zip for notarization (--sequesterRsrc preserves resource forks for Gatekeeper)
echo "==> Creating zip for notarization..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# Notarize
echo "==> Submitting for notarization (this may take a few minutes)..."
if ! xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait; then
    fail_release "Notarization failed. Run 'xcrun notarytool log' for details."
fi

# Staple the notarization ticket to the app
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
verify_gatekeeper_and_notarization "$APP_PATH"

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

echo "==> Creating branded DMG..."
create_branded_dmg

echo "==> Signing and notarizing DMG..."
sign_and_notarize_dmg
verify_dmg_artifact

generate_release_manifest "$APP_PATH" "$ZIP_PATH" "$DMG_PATH"

# Summary
echo ""
echo "============================================"
echo "  Release build complete!"
echo "============================================"
echo "  Version: $VERSION"
echo "  DMG:     $DMG_PATH"
echo "  ZIP:     $ZIP_PATH"
echo "  Manifest: $MANIFEST_PATH"
echo "  DMG Size: $(du -h "$DMG_PATH" | cut -f1)"
echo "  ZIP Size: $(du -h "$ZIP_PATH" | cut -f1)"
echo ""
echo "Next steps:"
echo "  • To publish now:  ./scripts/publish.sh $VERSION"
echo "    (or re-run with SKIP_BUILD=1 to skip the build step)"
echo "  • Upload $DMG_PATH to Gumroad / website manual-download slot"
echo ""
