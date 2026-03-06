#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION_NAME="${CONFIGURATION:-}"

if [[ "$CONFIGURATION_NAME" != "Release" ]]; then
  exit 0
fi

require_non_empty() {
  local value="$1"
  local name="$2"

  if [[ -z "${value// }" ]]; then
    echo "error: Missing required Release build setting: $name" >&2
    exit 1
  fi
}

if [[ "${CALOURA_REQUIRE_SIGNED_ENTITLEMENT:-}" != "YES" ]]; then
  echo "error: Release builds must set CALOURA_REQUIRE_SIGNED_ENTITLEMENT=YES" >&2
  exit 1
fi

require_non_empty "${CALOURA_LICENSE_ENTITLEMENT_URL:-}" "CALOURA_LICENSE_ENTITLEMENT_URL"
require_non_empty "${CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY:-}" "CALOURA_LICENSE_ENTITLEMENT_PUBLIC_KEY"
