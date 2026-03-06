#!/usr/bin/env python3
import argparse
import json
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def load_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_appcast(url: str | None, file_path: Path | None) -> bytes:
    if url:
        with urllib.request.urlopen(url) as response:
            return response.read()
    if file_path:
        return file_path.read_bytes()
    raise ValueError("Either --url or --file is required")


def first_item(root: ET.Element) -> ET.Element:
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("Appcast missing <channel>")
    item = channel.find("item")
    if item is None:
        raise SystemExit("Appcast missing <item>")
    return item


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a Sparkle appcast against a generated release manifest.")
    parser.add_argument("--manifest", required=True, help="Path to release manifest JSON")
    parser.add_argument("--url", help="Live appcast URL")
    parser.add_argument("--file", help="Local appcast XML path")
    args = parser.parse_args()

    if not args.url and not args.file:
        raise SystemExit("Either --url or --file must be provided")

    manifest = load_manifest(Path(args.manifest))
    root = ET.fromstring(
        load_appcast(args.url, Path(args.file) if args.file else None)
    )
    item = first_item(root)
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit("Appcast item missing <enclosure>")

    short_version = enclosure.attrib.get(
        f"{{{SPARKLE_NAMESPACE}}}shortVersionString", ""
    )
    build_number = enclosure.attrib.get(
        f"{{{SPARKLE_NAMESPACE}}}version", ""
    )
    minimum_system_version = enclosure.attrib.get(
        f"{{{SPARKLE_NAMESPACE}}}minimumSystemVersion", ""
    )

    expected_short_version = manifest.get("marketing_version", "")
    expected_build_number = str(manifest.get("build_number", ""))
    expected_minimum_system_version = manifest.get("minimum_system_version", "")

    mismatches = []
    if short_version != expected_short_version:
        mismatches.append(
            f"shortVersionString mismatch (manifest={expected_short_version} appcast={short_version})"
        )
    if build_number != expected_build_number:
        mismatches.append(
            f"version mismatch (manifest={expected_build_number} appcast={build_number})"
        )
    if minimum_system_version != expected_minimum_system_version:
        mismatches.append(
            "minimumSystemVersion mismatch "
            f"(manifest={expected_minimum_system_version} appcast={minimum_system_version})"
        )

    if mismatches:
        for mismatch in mismatches:
            print(mismatch)
        return 1

    print(
        "Appcast matches manifest:",
        f"version={short_version}",
        f"build={build_number}",
        f"minimumSystemVersion={minimum_system_version}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
