#!/usr/bin/env bash
# Single source of truth for installing the pinned XcodeGen.
#
# Downloads the exact XcodeGen release pinned in scripts/ci_tool_versions.env,
# verifies its SHA-256, unpacks it, self-checks the reported version, and prints
# the absolute path to the directory containing the `xcodegen` binary on stdout.
# All diagnostics go to stderr so stdout is ONLY the bin path.
#
# Consumers add the printed dir to PATH themselves:
#   local  (release_ready.sh):  export PATH="$(scripts/install_xcodegen.sh):$PATH"
#   GitHub (ci.yml / release-smoke.yml):  scripts/install_xcodegen.sh >> "$GITHUB_PATH"
#
# This exists because the committed Caloura.xcodeproj is byte-sensitive to the
# XcodeGen version (objectVersion / scheme parallelizable attributes changed
# across releases). Every consumer that runs `xcodegen generate` must use the
# same pinned version, or the drift gate red-flags a project that is actually
# in sync. Do not fall back to a PATH `xcodegen` of unknown version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/ci_tool_versions.env"

: "${XCODEGEN_VERSION:?XCODEGEN_VERSION missing from ci_tool_versions.env}"
: "${XCODEGEN_ZIP_SHA256:?XCODEGEN_ZIP_SHA256 missing from ci_tool_versions.env}"

install_dir="${XCODEGEN_INSTALL_DIR:-$(mktemp -d)}"
mkdir -p "$install_dir"
zip_path="$install_dir/xcodegen.zip"

curl -fsSL -o "$zip_path" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip" >&2
echo "${XCODEGEN_ZIP_SHA256}  ${zip_path}" | shasum -a 256 -c - >&2
unzip -o -q "$zip_path" -d "$install_dir"

# The zip extracts to xcodegen/bin/xcodegen with a sibling xcodegen/share the
# binary resolves relative to bin, so the bin dir must stay inside that layout.
bin_dir="$install_dir/xcodegen/bin"
installed="$("$bin_dir/xcodegen" version | awk '{print $2}')"
if [ "$installed" != "$XCODEGEN_VERSION" ]; then
  echo "::error::xcodegen $installed != pinned $XCODEGEN_VERSION (update scripts/ci_tool_versions.env deliberately)" >&2
  exit 1
fi
echo "xcodegen $installed installed at $bin_dir" >&2

echo "$bin_dir"
