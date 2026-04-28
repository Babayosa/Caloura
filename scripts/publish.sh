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
DMG_PATH="$BUILD_DIR/Caloura-$VERSION.dmg"
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

# Single source of truth for sign_update — the binary baked from the project's
# resolved Sparkle SPM package. Stray copies (~/Applications/Sparkle, brew, PATH)
# can drift to a different EdDSA build or a forked binary; refuse to fall back.
# Override only with SIGN_UPDATE_PATH (kept for parity with caloura-site's
# release.sh, which uses the same env var).
SIGN_UPDATE="${SIGN_UPDATE_PATH:-$PROJECT_DIR/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update}"
if [ ! -f "$SIGN_UPDATE" ]; then
    echo "Error: sign_update not found at $SIGN_UPDATE"
    echo "Resolve Sparkle first:"
    echo "  xcodebuild -resolvePackageDependencies -project $PROJECT_DIR/Caloura.xcodeproj -scheme Caloura -derivedDataPath $PROJECT_DIR/.build/xcode"
    echo "Or override with SIGN_UPDATE_PATH=/path/to/sign_update."
    exit 1
fi

if [ ! -d "$SITE_REPO/.git" ]; then
    echo "Error: Site repo not found at $SITE_REPO"
    echo "Clone it: git clone git@github.com:Babayosa/caloura-site.git $SITE_REPO"
    exit 1
fi

# Concurrent publish guard — two parallel runs racing on appcast.xml or pushing
# competing commits is the worst-case publish failure (silent overwrite, lost
# release). flock holds an exclusive lock for the lifetime of this process.
LOCK_FILE="$SITE_REPO/.publish.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Error: another publish is in progress (lock at $LOCK_FILE)."
        echo "       If certain no other publish runs, remove the lock file."
        exit 1
    fi
else
    # macOS ships without flock(1). Fall back to a directory mkdir lock — atomic
    # across processes, cleaned up on EXIT (including normal completion + signals).
    LOCK_DIR="$SITE_REPO/.publish.lock.d"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Error: another publish is in progress (lock at $LOCK_DIR)."
        echo "       If certain no other publish runs, remove the lock directory."
        exit 1
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

echo "========================================"
echo "  Caloura v$VERSION — Full Publish"
echo "========================================"
echo ""

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -f "$DMG_PATH" ] && [ -f "$MANIFEST_PATH" ]; then
    echo "==> Skipping build (SKIP_BUILD=1), using existing artifacts"

    # Even with SKIP_BUILD, verify the cached DMG bundles the requested version.
    # Without this check, a stale DMG from a prior release could be re-published
    # under a new tag — Sparkle would offer the wrong binary to users.
    VERIFY_MOUNT="$BUILD_DIR/dmg-skipbuild-verify"
    rm -rf "$VERIFY_MOUNT"
    mkdir -p "$VERIFY_MOUNT"
    hdiutil attach -quiet -readonly -noverify -noautoopen "$DMG_PATH" \
        -mountpoint "$VERIFY_MOUNT"
    DMG_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$VERIFY_MOUNT/Caloura.app/Contents/Info.plist" 2>/dev/null || true)"
    hdiutil detach -quiet "$VERIFY_MOUNT" || true
    rm -rf "$VERIFY_MOUNT"

    if [ -z "$DMG_BUNDLE_VERSION" ]; then
        echo "Error: could not read CFBundleShortVersionString from $DMG_PATH"
        exit 1
    fi
    if [ "$DMG_BUNDLE_VERSION" != "$VERSION" ]; then
        echo "Error: cached DMG version mismatch — $DMG_PATH bundles $DMG_BUNDLE_VERSION, expected $VERSION."
        echo "       Re-run without SKIP_BUILD=1, or move the stale DMG aside."
        exit 1
    fi
    echo "==> Cached DMG version check passed ($DMG_BUNDLE_VERSION)"
else
    echo "==> Step 1/3: Building and notarizing artifacts..."
    "$SCRIPT_DIR/release.sh" "$VERSION"
fi

# Resolve ZIP path from manifest (filename includes build number for CDN safety)
ZIP_PATH="$(manifest_value sparkle_artifact_path)"
ZIP_NAME="$(basename "$ZIP_PATH")"

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
IDEMPOTENT_PUBLISH_RERUN=0

# Highest build number currently published. Reading it from the appcast
# (rather than a sidecar file) keeps a single source of truth: the file we
# actually serve to users. Empty if no prior items exist.
PREVIOUS_BUILD_NUMBER="$(python3 - "$APPCAST_PATH" <<'PY'
import sys
import xml.etree.ElementTree as ET

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
try:
    root = ET.parse(sys.argv[1]).getroot()
except (FileNotFoundError, ET.ParseError):
    print("")
    sys.exit(0)

builds = []
for item in root.findall("./channel/item"):
    enclosure = item.find("enclosure")
    raw = ""
    if enclosure is not None:
        raw = enclosure.attrib.get(f"{{{NS}}}version", "")
    if not raw:
        sib = item.find(f"{{{NS}}}version")
        raw = sib.text if sib is not None and sib.text else ""
    try:
        builds.append(int(raw))
    except ValueError:
        continue

print(max(builds) if builds else "")
PY
)"

if [ -n "$PREVIOUS_BUILD_NUMBER" ]; then
    if [ "$BUILD_NUMBER" -lt "$PREVIOUS_BUILD_NUMBER" ]; then
        echo "Error: refusing to publish — build number $BUILD_NUMBER is not greater than previously-published $PREVIOUS_BUILD_NUMBER."
        echo "       Sparkle would treat this as a downgrade. Bump the build number and retry."
        exit 1
    fi

    if [ "$BUILD_NUMBER" -eq "$PREVIOUS_BUILD_NUMBER" ]; then
        echo "==> Build number $BUILD_NUMBER is already published; checking for an idempotent rerun..."
        if validate_appcast_against_manifest; then
            echo "==> Local appcast already matches manifest; continuing with live validation and QA."
            IDEMPOTENT_PUBLISH_RERUN=1
        else
            echo "Error: build number $BUILD_NUMBER is already published, but the local appcast does not match this manifest."
            echo "       Bump the build number for a new release, or repair the site repo before retrying."
            exit 1
        fi
    fi
fi

# Remove any historical autoupdate floor. Caloura releases should advertise
# the latest build to every eligible older app, not force chained updates.
python3 - "$APPCAST_PATH" <<'STRIP_MIN_AUTOUPDATE'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
filtered = [
    line for line in lines
    if "<sparkle:minimumAutoupdateVersion>" not in line
]
path.write_text("\n".join(filtered) + "\n", encoding="utf-8")
STRIP_MIN_AUTOUPDATE

if [ "$IDEMPOTENT_PUBLISH_RERUN" != "1" ]; then
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

    # Remove any existing appcast entry with the same shortVersionString
    # to prevent duplicate entries with conflicting signatures.
    python3 - "$APPCAST_PATH" "$VERSION" <<'DEDUP'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# Match <item> blocks containing this shortVersionString
pattern = (
    r'\s*<item>\s*'
    r'<title>Version ' + re.escape(version) + r'</title>'
    r'.*?</item>'
)
content = re.sub(pattern, '', content, flags=re.DOTALL)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
DEDUP

    sed -i '' "/<language>en<\/language>/r $TMPITEM" "$APPCAST_PATH"
fi
rm -f "$TMPITEM"

if [ "$IDEMPOTENT_PUBLISH_RERUN" != "1" ]; then
    sed -i '' -E "s#releases/Caloura-[0-9][0-9.]*(\.zip|\.dmg)#releases/$DMG_NAME#g" "$INDEX_PATH"
fi

validate_appcast_against_manifest

echo ""
echo "==> Step 3/3: Committing and pushing site changes..."
git -C "$SITE_REPO" add "releases/$ZIP_NAME" "releases/$DMG_NAME" appcast.xml index.html
if git -C "$SITE_REPO" diff --cached --quiet; then
    echo "No site changes to commit; continuing with live validation."
else
    git -C "$SITE_REPO" commit -m "Release v$VERSION"
    git -C "$SITE_REPO" push
fi

echo ""
echo "==> Validating live appcast after publish..."
if ! validate_live_appcast_against_manifest; then
    echo "Error: Live appcast validation failed after publish."
    echo "==> Attempting automatic rollback of the broken release..."

    BROKEN_SHA="$(git -C "$SITE_REPO" rev-parse HEAD)"
    echo "    broken commit: $BROKEN_SHA"

    if ! git -C "$SITE_REPO" revert HEAD --no-edit; then
        echo "Error: auto-revert failed. Manual recovery required:"
        echo "       cd \"$SITE_REPO\" && git revert $BROKEN_SHA && git push"
        echo "       Or roll forward with a corrected publish."
        exit 1
    fi

    if ! git -C "$SITE_REPO" push; then
        echo "Error: revert commit was created but push failed. Manual recovery:"
        echo "       cd \"$SITE_REPO\" && git push"
        echo "       The broken release is still live until the revert is pushed."
        exit 1
    fi

    REVERT_SHA="$(git -C "$SITE_REPO" rev-parse HEAD)"
    echo "==> Rolled back automatically. Revert commit: $REVERT_SHA"
    echo "    Users on the previous version will not be offered the broken update."
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
