#!/usr/bin/env bash
set -euo pipefail

MINUTES=30
OUTPUT_DIR="build/perf-audit"
SUBSYSTEM="com.caloura.app"
CATEGORY="CaptureTimeline"
LABEL="$(date +%Y%m%d-%H%M%S)"
STRICT=0
MIN_SAMPLES=5

usage() {
  cat <<'USAGE'
Usage:
  scripts/perf_audit.sh [--minutes <n>] [--output-dir <path>] [--label <name>] [--strict] [--min-samples <n>]

What it does:
  1. Reads recent Caloura capture timeline logs from CapturePerformanceRecorder.
  2. Produces CSV + Markdown summaries with p50/p95 by mode/event.
  3. Evaluates release budgets for area, fullscreen, window, and preview presentation.

Notes:
  - Run a few real captures first so the recorder has samples to analyze.
  - Use --strict to fail when any required budget is missing data.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes)
      MINUTES="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --min-samples)
      MIN_SAMPLES="$2"
      shift 2
      ;;
    --strict)
      STRICT=1
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to summarize capture timeline metrics."
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

TMP_LOGS="$(mktemp)"
trap 'rm -f "$TMP_LOGS"' EXIT

echo "Collecting capture timeline logs from the last ${MINUTES} minute(s)..."
log show \
  --style compact \
  --info \
  --last "${MINUTES}m" \
  --predicate "subsystem == \"$SUBSYSTEM\" AND category == \"$CATEGORY\" AND eventMessage CONTAINS \"capture_timeline\"" \
  > "$TMP_LOGS"

if [[ ! -s "$TMP_LOGS" ]]; then
  echo "No capture_timeline logs found."
  echo "Generate logs by running real area, fullscreen, and window captures, then rerun this script."
  exit 1
fi

DISPLAY_COUNT="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution' || true)"
if [[ -z "$DISPLAY_COUNT" || "$DISPLAY_COUNT" -lt 1 ]]; then
  DISPLAY_COUNT=1
fi

OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
OS_BUILD="$(sw_vers -buildVersion 2>/dev/null || echo "unknown")"
HARDWARE_MODEL="$(sysctl -n hw.model 2>/dev/null || echo "unknown")"
CPU_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")"

python3 - "$TMP_LOGS" "$OUTPUT_DIR" "$LABEL" "$DISPLAY_COUNT" "$MINUTES" "$STRICT" "$MIN_SAMPLES" "$OS_VERSION" "$OS_BUILD" "$HARDWARE_MODEL" "$CPU_BRAND" <<'PY'
import csv
import datetime as dt
import os
import re
import statistics
import sys

(
    log_path,
    output_dir,
    label,
    display_count_raw,
    minutes_raw,
    strict_raw,
    min_samples_raw,
    os_version,
    os_build,
    hardware_model,
    cpu_brand,
) = sys.argv[1:12]

display_count = int(display_count_raw)
minutes = minutes_raw
strict = strict_raw == "1"
min_samples = int(min_samples_raw)

pattern = re.compile(
    r"capture_timeline mode=([a-z_]+) event=([a-z_]+) (?:ms|duration_ms)=([0-9]+(?:\.[0-9]+)?)"
)
samples: dict[tuple[str, str], list[float]] = {}

with open(log_path, "r", encoding="utf-8", errors="ignore") as fh:
    for line in fh:
        match = pattern.search(line)
        if not match:
            continue
        mode, event, value_raw = match.groups()
        value = float(value_raw)
        samples.setdefault((mode, event), []).append(value)

if not samples:
    print("No parseable capture_timeline samples found.")
    print("Generate logs by running real captures, then rerun this script.")
    sys.exit(1)


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    idx = int((len(ordered) - 1) * p)
    return ordered[idx]


rows = []
for (mode, event), values in sorted(samples.items()):
    ordered = sorted(values)
    rows.append({
        "mode": mode,
        "event": event,
        "count": len(ordered),
        "min_ms": ordered[0],
        "mean_ms": statistics.fmean(ordered),
        "p50_ms": percentile(ordered, 0.50),
        "p95_ms": percentile(ordered, 0.95),
        "max_ms": ordered[-1],
    })

row_map = {(row["mode"], row["event"]): row for row in rows}
timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
csv_path = os.path.join(output_dir, f"capture-perf-{label}-{timestamp}.csv")
md_path = os.path.join(output_dir, f"capture-perf-{label}-{timestamp}.md")

with open(csv_path, "w", newline="", encoding="utf-8") as csv_file:
    writer = csv.DictWriter(
        csv_file,
        fieldnames=[
            "mode",
            "event",
            "count",
            "min_ms",
            "mean_ms",
            "p50_ms",
            "p95_ms",
            "max_ms",
        ],
    )
    writer.writeheader()
    for row in rows:
        writer.writerow({
            "mode": row["mode"],
            "event": row["event"],
            "count": row["count"],
            "min_ms": f"{row['min_ms']:.2f}",
            "mean_ms": f"{row['mean_ms']:.2f}",
            "p50_ms": f"{row['p50_ms']:.2f}",
            "p95_ms": f"{row['p95_ms']:.2f}",
            "max_ms": f"{row['max_ms']:.2f}",
        })

gates = []

if display_count <= 1:
    gates.append(("Area overlay visible", "area", "overlay_visible", 100.0, 160.0))
    gates.append(("Fullscreen preview visible", "fullscreen", "raw_preview_visible", 150.0, 250.0))
else:
    gates.append(("Area overlay visible", "area", "overlay_visible", 150.0, 240.0))
    gates.append(("Fullscreen selector visible", "fullscreen", "overlay_visible", 80.0, 140.0))

gates.extend([
    ("Window picker visible (warm)", "window", "picker_visible_warm", 150.0, 250.0),
    ("Window picker visible (cold)", "window", "picker_visible_cold", 250.0, 400.0),
    ("Area preview presentation", "area", "preview_presentation_duration", 50.0, 80.0),
    ("Fullscreen preview presentation", "fullscreen", "preview_presentation_duration", 50.0, 80.0),
    ("Window preview presentation", "window", "preview_presentation_duration", 50.0, 80.0),
])

gate_rows = []
hard_failures = []
missing_gates = []
insufficient_sample_gates = []

for label_text, mode, event, p50_limit, p95_limit in gates:
    row = row_map.get((mode, event))
    if row is None:
        gate_rows.append({
            "gate": label_text,
            "mode": mode,
            "event": event,
            "status": "NO_DATA",
            "p50_limit": p50_limit,
            "p95_limit": p95_limit,
            "p50_ms": None,
            "p95_ms": None,
        })
        missing_gates.append(label_text)
        continue

    if strict and row["count"] < min_samples:
        gate_rows.append({
            "gate": label_text,
            "mode": mode,
            "event": event,
            "status": "INSUFFICIENT_DATA",
            "p50_limit": p50_limit,
            "p95_limit": p95_limit,
            "p50_ms": row["p50_ms"],
            "p95_ms": row["p95_ms"],
        })
        insufficient_sample_gates.append(
            f"{label_text} (n={row['count']}, required={min_samples})"
        )
        continue

    passed = row["p50_ms"] <= p50_limit and row["p95_ms"] <= p95_limit
    status = "PASS" if passed else "FAIL"
    gate_rows.append({
        "gate": label_text,
        "mode": mode,
        "event": event,
        "status": status,
        "p50_limit": p50_limit,
        "p95_limit": p95_limit,
        "p50_ms": row["p50_ms"],
        "p95_ms": row["p95_ms"],
    })
    if not passed:
        hard_failures.append(label_text)

with open(md_path, "w", encoding="utf-8") as md:
    md.write("# Caloura Capture Performance Audit\n\n")
    md.write(f"- Generated: {dt.datetime.now().isoformat(timespec='seconds')}\n")
    md.write(f"- Window: last {minutes} minute(s)\n")
    md.write(f"- macOS: {os_version} ({os_build})\n")
    md.write(f"- Hardware: {hardware_model}\n")
    md.write(f"- CPU: {cpu_brand}\n")
    md.write(f"- Display count detected: {display_count}\n")
    md.write(f"- Strict missing-data mode: {'on' if strict else 'off'}\n\n")
    md.write(f"- Minimum samples per gate: {min_samples}\n\n")

    md.write("## Release Gates\n\n")
    md.write("| Gate | Mode | Event | Status | p50 limit | p95 limit | p50 | p95 |\n")
    md.write("| --- | --- | --- | --- | ---: | ---: | ---: | ---: |\n")
    for gate in gate_rows:
        p50_value = "n/a" if gate["p50_ms"] is None else f"{gate['p50_ms']:.2f}"
        p95_value = "n/a" if gate["p95_ms"] is None else f"{gate['p95_ms']:.2f}"
        md.write(
            f"| {gate['gate']} | {gate['mode']} | {gate['event']} | {gate['status']} | "
            f"{gate['p50_limit']:.0f} | {gate['p95_limit']:.0f} | {p50_value} | {p95_value} |\n"
        )

    md.write("\n## Samples\n\n")
    md.write("| Mode | Event | Count | Min | Mean | p50 | p95 | Max |\n")
    md.write("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |\n")
    for row in rows:
        md.write(
            f"| {row['mode']} | {row['event']} | {row['count']} | {row['min_ms']:.2f} | "
            f"{row['mean_ms']:.2f} | {row['p50_ms']:.2f} | {row['p95_ms']:.2f} | {row['max_ms']:.2f} |\n"
        )

print(f"CSV summary: {csv_path}")
print(f"Markdown summary: {md_path}")

if hard_failures:
    print("Performance budget failures:")
    for label_text in hard_failures:
        print(f"  - {label_text}")
    sys.exit(2)

if strict and missing_gates:
    print("Missing performance gate data:")
    for label_text in missing_gates:
        print(f"  - {label_text}")
    sys.exit(3)

if strict and insufficient_sample_gates:
    print("Insufficient performance gate samples:")
    for label_text in insufficient_sample_gates:
        print(f"  - {label_text}")
    sys.exit(4)
PY

echo "Performance audit summaries written to: $OUTPUT_DIR"
