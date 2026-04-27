#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA_PATH="$PROJECT_DIR/.build/DerivedData"
OUTPUT_DIR="$PROJECT_DIR/build/release-ready"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_LOG="$OUTPUT_DIR/xcodebuild-build-$TIMESTAMP.log"
TEST_LOG="$OUTPUT_DIR/xcodebuild-test-$TIMESTAMP.log"
RESULT_BUNDLE_PATH="$OUTPUT_DIR/xcodebuild-test-$TIMESTAMP.xcresult"
UI_TEST_LOG="$OUTPUT_DIR/xcodebuild-ui-test-$TIMESTAMP.log"
UI_RESULT_BUNDLE_PATH="$OUTPUT_DIR/xcodebuild-ui-test-$TIMESTAMP.xcresult"
CAPTURE_REPEAT_DERIVED_DATA_PATH="$PROJECT_DIR/.build/DerivedData-capture-repeat"
PERF_MINUTES=30
CAPTURE_STABILITY_RUNS="${CAPTURE_STABILITY_RUNS:-10}"
VERSION=""
SKIP_PERFORMANCE=0
GUARD_ONLY=0
UI_TEST_TIMEOUT_SECONDS="${UI_TEST_TIMEOUT_SECONDS:-180}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/release_ready.sh [--version <semver>] [--perf-minutes <n>] [--skip-performance] [--guard-only]

What it does:
  1. Runs the required local validation stack.
  2. Fails on any Xcode build/test warnings.
  3. Runs unit/system Xcode tests, then dedicated UI smoke tests with an automation preflight.
  4. Runs the release packaging/signing/notarization path (or guard-only checks with --guard-only).
  5. Optionally runs the capture performance audit against recent local logs.

Notes:
  - Use --skip-performance only when you are explicitly waiving local perf evidence for this run.
  - Use --guard-only only when you intentionally want to skip full packaging/notarization validation.
  - Live appcast validation happens in scripts/publish.sh after the site repo is updated.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --perf-minutes)
      PERF_MINUTES="$2"
      shift 2
      ;;
    --skip-performance)
      SKIP_PERFORMANCE=1
      shift
      ;;
    --guard-only)
      GUARD_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

read_plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

info_plist="$PROJECT_DIR/Caloura/Resources/Info.plist"
if [[ -z "$VERSION" ]]; then
  VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_DIR/project.yml")"
fi
MANIFEST_PATH="$PROJECT_DIR/build/release-manifest-$VERSION.json"

if [[ -z "$VERSION" ]]; then
  echo "ERROR: Could not determine MARKETING_VERSION. Pass --version explicitly."
  exit 1
fi

MIN_SYSTEM_VERSION="$(read_plist_value "$info_plist" "LSMinimumSystemVersion")"

if [[ -z "$MIN_SYSTEM_VERSION" ]]; then
  echo "ERROR: LSMinimumSystemVersion is missing from $info_plist"
  exit 1
fi

run_step() {
  echo ""
  echo "==> $1"
}

check_log_for_warnings() {
  local log_file="$1"
  if grep -n "warning:" "$log_file" >/dev/null; then
    echo "ERROR: warnings found in $(basename "$log_file")"
    grep -n "warning:" "$log_file"
    exit 1
  fi
}

run_step "swift build"
(cd "$PROJECT_DIR" && swift build)

run_step "swiftlint lint --quiet"
(cd "$PROJECT_DIR" && swiftlint lint --quiet)

run_step "swift test"
(cd "$PROJECT_DIR" && swift test)

run_step "xcodegen generate"
(cd "$PROJECT_DIR" && xcodegen generate)

run_step "Xcode project drift check"
(
  cd "$PROJECT_DIR"
  git diff --exit-code -- Caloura.xcodeproj
)

run_step "xcodebuild build"
(
  cd "$PROJECT_DIR"
  xcodebuild build \
    -project Caloura.xcodeproj \
    -scheme Caloura \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination 'platform=macOS,arch=arm64' \
    2>&1 | tee "$BUILD_LOG"
)
check_log_for_warnings "$BUILD_LOG"

run_step "xcodebuild test"
(
  cd "$PROJECT_DIR"
  xcodebuild test \
    -project Caloura.xcodeproj \
    -scheme Caloura \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -enableCodeCoverage YES \
    -skip-testing:CalouraUITests \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    -destination 'platform=macOS,arch=arm64' \
    2>&1 | tee "$TEST_LOG"
)
check_log_for_warnings "$TEST_LOG"

run_step "Capture entrypoint Xcode stability loop (${CAPTURE_STABILITY_RUNS}x)"
for run in $(seq 1 "$CAPTURE_STABILITY_RUNS"); do
  capture_log="$OUTPUT_DIR/xcodebuild-capture-repeat-$TIMESTAMP-$run.log"
  (
    cd "$PROJECT_DIR"
    xcodebuild test \
      -project Caloura.xcodeproj \
      -scheme Caloura \
      -configuration Debug \
      -derivedDataPath "$CAPTURE_REPEAT_DERIVED_DATA_PATH" \
      -only-testing:CalouraTests/CapturePipelineEntryPointTests \
      -only-testing:CalouraSystemTests/CaptureSystemTests/testAreaCaptureCrosshairPersistsAcrossFiveCaptures \
      -only-testing:CalouraSystemTests/CaptureSystemTests/testAreaCaptureCrosshairRecoversAfterPoolTeardownBypass \
      -destination 'platform=macOS,arch=arm64' \
      >"$capture_log" 2>&1
  )
  check_log_for_warnings "$capture_log"
done

run_step "Coverage gate"
python3 "$PROJECT_DIR/scripts/coverage_gate.py" \
  --xcresult "$RESULT_BUNDLE_PATH" \
  --output-dir "$OUTPUT_DIR"

run_step "UI automation environment preflight"
"$PROJECT_DIR/scripts/validate_ui_automation_environment.sh"

run_step "Dedicated UI smoke tests"
UI_TEST_TIMEOUT_MARKER="$OUTPUT_DIR/xcodebuild-ui-test-$TIMESTAMP.timeout"
rm -f "$UI_TEST_TIMEOUT_MARKER" "$UI_TEST_LOG"
set +e
(
  cd "$PROJECT_DIR"
  xcodebuild test \
    -project Caloura.xcodeproj \
    -scheme Caloura \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -only-testing:CalouraUITests \
    -resultBundlePath "$UI_RESULT_BUNDLE_PATH" \
    -destination 'platform=macOS,arch=arm64' \
    >"$UI_TEST_LOG" 2>&1
) &
ui_test_pid=$!
(
  sleep "$UI_TEST_TIMEOUT_SECONDS"
  if kill -0 "$ui_test_pid" 2>/dev/null; then
    echo "Timed out after ${UI_TEST_TIMEOUT_SECONDS}s" > "$UI_TEST_TIMEOUT_MARKER"
    kill -TERM "$ui_test_pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$ui_test_pid" 2>/dev/null || true
  fi
) &
ui_timeout_pid=$!
wait "$ui_test_pid"
ui_test_exit=$?
kill "$ui_timeout_pid" 2>/dev/null || true
wait "$ui_timeout_pid" 2>/dev/null || true
set -e
if [[ -f "$UI_TEST_LOG" ]]; then
  cat "$UI_TEST_LOG"
fi
if [[ "$ui_test_exit" -ne 0 ]]; then
  if [[ -f "$UI_TEST_TIMEOUT_MARKER" ]]; then
    echo "ERROR: UI smoke tests timed out after ${UI_TEST_TIMEOUT_SECONDS}s." >&2
    echo "Inspect $UI_TEST_LOG and verify Xcode automation permissions and desktop-session state." >&2
    exit 1
  fi
  if grep -n "Timed out while enabling automation mode" "$UI_TEST_LOG" >/dev/null; then
    echo "ERROR: UI smoke tests failed because macOS could not enable automation mode." >&2
    echo "Run scripts/validate_ui_automation_environment.sh from the logged-in desktop session" >&2
    echo "and grant Accessibility access to Xcode plus the Xcode UI-testing helper app." >&2
  fi
  exit "$ui_test_exit"
fi
check_log_for_warnings "$UI_TEST_LOG"

if [[ "$GUARD_ONLY" -eq 1 ]]; then
  run_step "Release metadata guards"
  (
    cd "$PROJECT_DIR"
    RELEASE_GUARD_ONLY=1 RELEASE_TAG="v$VERSION" ./scripts/release.sh "$VERSION"
  )
else
  run_step "Release packaging, signing, and notarization"
  (
    cd "$PROJECT_DIR"
    RELEASE_TAG="v$VERSION" ./scripts/release.sh "$VERSION"
  )
fi

if [[ "$SKIP_PERFORMANCE" -eq 1 ]]; then
  echo ""
  echo "==> Performance audit skipped by explicit waiver (--skip-performance)"
else
  run_step "Capture performance audit"
  (
    cd "$PROJECT_DIR"
    ./scripts/perf_audit.sh \
      --minutes "$PERF_MINUTES" \
      --output-dir "$OUTPUT_DIR" \
      --label "release-ready" \
      --strict
  )
fi

echo ""
echo "Release readiness checks passed."
echo "Build log: $BUILD_LOG"
echo "Test log:  $TEST_LOG"
