#!/usr/bin/env bash
set -euo pipefail

MINUTES=30
OUTPUT_DIR="build/perf-audit"
SUBSYSTEM="com.caloura.app"
LABEL="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<'USAGE'
Usage:
  scripts/perf_audit.sh [--minutes <n>] [--output-dir <path>] [--label <name>]

What it does:
  1. Reads recent Caloura performance logs (metric_sample events).
  2. Produces CSV + Markdown summaries with p50/p95 by stage.
  3. Evaluates KPI gates for overlay entry, clipboard-ready total, and history open.
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

TMP_LOGS="$(mktemp)"
trap 'rm -f "$TMP_LOGS"' EXIT

echo "Collecting metrics from the last ${MINUTES} minute(s)..."
log show \
  --style compact \
  --last "${MINUTES}m" \
  --predicate "subsystem == \"$SUBSYSTEM\" AND eventMessage CONTAINS \"metric_sample stage=\"" \
  > "$TMP_LOGS"

if [[ ! -s "$TMP_LOGS" ]]; then
  echo "No metric_sample logs found. Run a few captures first, then rerun this script."
  exit 1
fi

DISPLAY_COUNT="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution' || true)"
if [[ -z "$DISPLAY_COUNT" || "$DISPLAY_COUNT" -lt 1 ]]; then
  DISPLAY_COUNT=1
fi

python3 - "$TMP_LOGS" "$OUTPUT_DIR" "$LABEL" "$DISPLAY_COUNT" <<'PY'
import csv
import datetime as dt
import math
import os
import re
import statistics
import sys

log_path, output_dir, label, display_count_raw = sys.argv[1:5]
display_count = int(display_count_raw)

pattern = re.compile(r"metric_sample stage=([a-z_]+) ms=([0-9]+(?:\.[0-9]+)?)")
samples = {}

with open(log_path, "r", encoding="utf-8", errors="ignore") as fh:
    for line in fh:
        match = pattern.search(line)
        if not match:
            continue
        stage = match.group(1)
        value = float(match.group(2))
        samples.setdefault(stage, []).append(value)

if not samples:
    print("No parseable metric_sample rows found.")
    sys.exit(1)

def percentile(values, p):
    ordered = sorted(values)
    idx = int((len(ordered) - 1) * p)
    return ordered[idx]

rows = []
for stage, values in sorted(samples.items()):
    ordered = sorted(values)
    rows.append({
        "stage": stage,
        "count": len(ordered),
        "min_ms": ordered[0],
        "mean_ms": statistics.fmean(ordered),
        "p50_ms": percentile(ordered, 0.50),
        "p95_ms": percentile(ordered, 0.95),
        "max_ms": ordered[-1],
    })

timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
csv_path = os.path.join(output_dir, f"perf-summary-{label}-{timestamp}.csv")
md_path = os.path.join(output_dir, f"perf-summary-{label}-{timestamp}.md")

with open(csv_path, "w", newline="", encoding="utf-8") as csv_file:
    writer = csv.DictWriter(
        csv_file,
        fieldnames=["stage", "count", "min_ms", "mean_ms", "p50_ms", "p95_ms", "max_ms"]
    )
    writer.writeheader()
    for row in rows:
        writer.writerow({
            "stage": row["stage"],
            "count": row["count"],
            "min_ms": f"{row['min_ms']:.2f}",
            "mean_ms": f"{row['mean_ms']:.2f}",
            "p50_ms": f"{row['p50_ms']:.2f}",
            "p95_ms": f"{row['p95_ms']:.2f}",
            "max_ms": f"{row['max_ms']:.2f}",
        })

stage_map = {row["stage"]: row for row in rows}
overlay_threshold = 80.0 if display_count <= 1 else 120.0
total_threshold = 350.0
history_threshold = 120.0

def gate(stage, threshold):
    row = stage_map.get(stage)
    if not row:
        return ("NO_DATA", None)
    return ("PASS" if row["p95_ms"] <= threshold else "FAIL", row["p95_ms"])

overlay_gate, overlay_value = gate("overlay_visible", overlay_threshold)
total_gate, total_value = gate("total", total_threshold)
history_gate, history_value = gate("history_window_open", history_threshold)

with open(md_path, "w", encoding="utf-8") as md:
    md.write("# Caloura Performance Audit Summary\n\n")
    md.write(f"- Generated: {dt.datetime.now().isoformat(timespec='seconds')}\n")
    md.write(f"- Display count detected: {display_count}\n")
    md.write(f"- Overlay p95 gate: <= {overlay_threshold:.0f} ms\n")
    md.write(f"- Total p95 gate: <= {total_threshold:.0f} ms\n")
    md.write(f"- History open p95 gate: <= {history_threshold:.0f} ms\n\n")

    md.write("## KPI Gates\n\n")
    md.write("| Gate | Status | p95 (ms) |\n")
    md.write("| --- | --- | ---: |\n")
    md.write(f"| overlay_visible | {overlay_gate} | {overlay_value:.2f} |\n" if overlay_value is not None else f"| overlay_visible | {overlay_gate} | n/a |\n")
    md.write(f"| total | {total_gate} | {total_value:.2f} |\n" if total_value is not None else f"| total | {total_gate} | n/a |\n")
    md.write(f"| history_window_open | {history_gate} | {history_value:.2f} |\n" if history_value is not None else f"| history_window_open | {history_gate} | n/a |\n")

    md.write("\n## Stage Distribution\n\n")
    md.write("| Stage | Count | Min | Mean | p50 | p95 | Max |\n")
    md.write("| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n")
    for row in rows:
        md.write(
            f"| {row['stage']} | {row['count']} | {row['min_ms']:.2f} | {row['mean_ms']:.2f} | "
            f"{row['p50_ms']:.2f} | {row['p95_ms']:.2f} | {row['max_ms']:.2f} |\n"
        )

print(f"CSV summary: {csv_path}")
print(f"Markdown summary: {md_path}")

if overlay_gate == "FAIL" or total_gate == "FAIL" or history_gate == "FAIL":
    sys.exit(2)
PY

echo "Performance audit summaries written to: $OUTPUT_DIR"
