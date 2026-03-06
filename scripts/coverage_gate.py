#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path


DEFAULT_THRESHOLDS = {
    "Caloura/App/CapturePipeline+EntryPoints.swift": 80.0,
    "Caloura/Capture/WindowPickerManager.swift": 85.0,
    "Caloura/Capture/ScreenCaptureManager+Permission.swift": 85.0,
    "Caloura/App/UpdateManager.swift": 85.0,
    "Caloura/Capture/ScrollCaptureEngine.swift": 80.0,
    "Caloura/App/LicenseManager.swift": 90.0,
}


def load_xccov_report(xcresult_path: Path) -> dict:
    completed = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", str(xcresult_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def iter_files(node: dict):
    if isinstance(node, dict):
        if "files" in node:
            for file_node in node.get("files", []):
                yield from iter_files(file_node)
        if "path" in node and "lineCoverage" in node:
            yield node
        if "targets" in node:
            for target in node.get("targets", []):
                yield from iter_files(target)
    elif isinstance(node, list):
        for item in node:
            yield from iter_files(item)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fail if critical source files fall below required Xcode coverage thresholds.")
    parser.add_argument("--xcresult", required=True, help="Path to the xcodebuild result bundle")
    parser.add_argument("--output-dir", required=True, help="Directory for JSON/Markdown summaries")
    args = parser.parse_args()

    xcresult_path = Path(args.xcresult)
    if not xcresult_path.exists():
        raise SystemExit(f"xcresult bundle not found: {xcresult_path}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    report = load_xccov_report(xcresult_path)
    coverage_by_suffix: dict[str, float] = {}

    for file_node in iter_files(report):
        path = str(file_node.get("path", ""))
        line_coverage = file_node.get("lineCoverage")
        if not path or line_coverage is None:
            continue
        for suffix in DEFAULT_THRESHOLDS:
            if path.endswith(suffix):
                coverage_by_suffix[suffix] = max(
                    coverage_by_suffix.get(suffix, 0.0),
                    float(line_coverage) * 100.0,
                )

    summary = []
    failures = []
    missing = []

    for suffix, threshold in DEFAULT_THRESHOLDS.items():
        coverage = coverage_by_suffix.get(suffix)
        if coverage is None:
            status = "NO_DATA"
            missing.append(suffix)
        elif coverage >= threshold:
            status = "PASS"
        else:
            status = "FAIL"
            failures.append(f"{suffix} ({coverage:.2f}% < {threshold:.2f}%)")
        summary.append(
            {
                "file": suffix,
                "threshold_percent": threshold,
                "coverage_percent": coverage,
                "status": status,
            }
        )

    json_path = output_dir / "coverage-gate.json"
    md_path = output_dir / "coverage-gate.md"
    json_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    with md_path.open("w", encoding="utf-8") as handle:
        handle.write("# Coverage Gate\n\n")
        handle.write("| File | Threshold | Coverage | Status |\n")
        handle.write("| --- | ---: | ---: | --- |\n")
        for row in summary:
            coverage_text = "n/a" if row["coverage_percent"] is None else f"{row['coverage_percent']:.2f}%"
            handle.write(
                f"| {row['file']} | {row['threshold_percent']:.0f}% | {coverage_text} | {row['status']} |\n"
            )

    print(f"Coverage summary: {md_path}")

    if missing:
        print("Missing coverage data:")
        for file_path in missing:
            print(f"  - {file_path}")
        return 2

    if failures:
        print("Coverage threshold failures:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("Coverage thresholds passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
