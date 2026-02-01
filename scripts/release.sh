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

echo "==> Building $APP_NAME v$VERSION"
echo ""

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
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
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

# Verify code signature
echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature valid"

# Create zip for notarization
echo "==> Creating zip for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Notarize
echo "==> Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "Caloura-Notarize" \
    --wait

# Staple the notarization ticket to the app
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

# Re-create zip with the stapled app
rm "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

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
echo "  1. Upload $ZIP_PATH to Gumroad"
echo "  2. Update the Sparkle appcast (if configured):"
echo "     Download generate_appcast from Sparkle releases, then:"
echo "     ./generate_appcast $BUILD_DIR"
echo "     Push the updated appcast.xml to your hosting repo"
echo ""
