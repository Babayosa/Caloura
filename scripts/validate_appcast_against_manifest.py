#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RELEASE_BASE_URL = "https://caloura.app/releases/"


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


def find_sign_update() -> str:
    project_root = Path(__file__).resolve().parent.parent
    candidates = [
        project_root / ".build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update",
        Path.home() / "Applications" / "Sparkle" / "bin" / "sign_update",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    # No PATH fallback: an attacker-controlled sign_update earlier in PATH
    # could vouch for a tampered artifact. Only the pinned locations count.
    raise SystemExit("sign_update not found; build the project or install Sparkle.")


def sparkle_signature(artifact_path: Path) -> str:
    sign_update = find_sign_update()
    output = subprocess.check_output([sign_update, str(artifact_path)], text=True)
    match = re.search(r'sparkle:edSignature="([^"]+)"', output)
    if not match:
        raise SystemExit("Could not extract Sparkle edSignature from sign_update output")
    return match.group(1)


def first_item(root: ET.Element) -> ET.Element:
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("Appcast missing <channel>")
    item = channel.find("item")
    if item is None:
        raise SystemExit("Appcast missing <item>")
    return item


def all_items(root: ET.Element) -> list[ET.Element]:
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("Appcast missing <channel>")
    return channel.findall("item")


def parse_build_number(item: ET.Element) -> int:
    """Read the integer sparkle:version from an <item>.

    Prefers the value on <enclosure> (the field Sparkle actually compares),
    falls back to the sibling <sparkle:version> tag inside <item>.
    """
    enclosure = item.find("enclosure")
    if enclosure is not None:
        raw = enclosure.attrib.get(f"{{{SPARKLE_NAMESPACE}}}version", "")
        if raw:
            try:
                return int(raw)
            except ValueError:
                pass
    sibling = item.find(f"{{{SPARKLE_NAMESPACE}}}version")
    if sibling is not None and sibling.text:
        try:
            return int(sibling.text)
        except ValueError:
            pass
    raise SystemExit("Appcast item missing sparkle:version")


def detect_downgrade(items: list[ET.Element]) -> str | None:
    """Return an error message if the appcast advertises a downgrade.

    Sparkle treats the first <item> as the candidate update. If any later
    item exposes a higher build number, an attacker (or a publish-script
    bug) has effectively downgraded the offered version. EdDSA cannot
    catch this since the older item is also signed. Reject by structure.
    """
    if not items:
        return "Appcast has no <item>"
    first_build = parse_build_number(items[0])
    for index, item in enumerate(items[1:], start=1):
        build = parse_build_number(item)
        if build > first_build:
            return (
                "downgrade detected: item[0] has sparkle:version "
                f"{first_build} but item[{index}] has higher version {build}"
            )
    return None


def detect_minimum_autoupdate_version(items: list[ET.Element]) -> str | None:
    for index, item in enumerate(items):
        minimum = item.find(f"{{{SPARKLE_NAMESPACE}}}minimumAutoupdateVersion")
        if minimum is not None:
            version = minimum.text or ""
            return (
                "minimumAutoupdateVersion detected: "
                f"item[{index}] gates updates at build {version}. "
                "Caloura appcasts must let eligible older versions update directly to latest."
            )
    return None


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
    items = all_items(root)
    downgrade_error = detect_downgrade(items)
    if downgrade_error:
        print(downgrade_error)
        return 1
    minimum_autoupdate_error = detect_minimum_autoupdate_version(items)
    if minimum_autoupdate_error:
        print(minimum_autoupdate_error)
        return 1
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit("Appcast item missing <enclosure>")

    artifact_path_value = manifest.get("sparkle_artifact_path", "")
    if not artifact_path_value:
        raise SystemExit("Manifest missing sparkle_artifact_path")
    artifact_path = Path(artifact_path_value)
    if not artifact_path.is_file():
        raise SystemExit(f"Sparkle artifact not found at {artifact_path}")

    short_version = enclosure.attrib.get(
        f"{{{SPARKLE_NAMESPACE}}}shortVersionString", ""
    )
    build_number = enclosure.attrib.get(
        f"{{{SPARKLE_NAMESPACE}}}version", ""
    )
    minimum_system_version = enclosure.attrib.get(
        f"{{{SPARKLE_NAMESPACE}}}minimumSystemVersion", ""
    )
    enclosure_url = enclosure.attrib.get("url", "")
    enclosure_length = enclosure.attrib.get("length", "")
    enclosure_signature = enclosure.attrib.get(f"{{{SPARKLE_NAMESPACE}}}edSignature", "")

    expected_short_version = manifest.get("marketing_version", "")
    expected_build_number = str(manifest.get("build_number", ""))
    expected_minimum_system_version = manifest.get("minimum_system_version", "")
    expected_url = f"{RELEASE_BASE_URL}{artifact_path.name}"
    expected_length = str(artifact_path.stat().st_size)
    expected_signature = sparkle_signature(artifact_path)

    mismatches = []
    if enclosure_url != expected_url:
        mismatches.append(
            f"enclosure url mismatch (manifest={expected_url} appcast={enclosure_url})"
        )
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
    if enclosure_length != expected_length:
        mismatches.append(
            f"length mismatch (manifest={expected_length} appcast={enclosure_length})"
        )
    if enclosure_signature != expected_signature:
        mismatches.append(
            "edSignature mismatch "
            f"(manifest={expected_signature} appcast={enclosure_signature})"
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
