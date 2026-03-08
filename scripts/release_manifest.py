#!/usr/bin/env python3
import argparse
import json
import plistlib
from datetime import datetime, timezone
from pathlib import Path


def parse_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes"}
    return False


def build_manifest_from_info(
    info: dict,
    app_path: str,
    artifact_path: str,
    sparkle_artifact_path: str = "",
    manual_download_artifact_path: str = "",
    bundle_identifier: str | None = None,
    marketing_version: str | None = None,
    build_number: str | None = None,
    minimum_system_version: str | None = None,
    release_channel: str | None = None,
    requires_signed_entitlement: bool | None = None,
    entitlement_service_url: str | None = None,
    entitlement_public_key_configured: bool | None = None,
) -> dict:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "app_name": info.get("CFBundleName", "Caloura"),
        "bundle_identifier": bundle_identifier if bundle_identifier is not None else info.get("CFBundleIdentifier", ""),
        "marketing_version": marketing_version if marketing_version is not None else info.get("CFBundleShortVersionString", ""),
        "build_number": str(build_number if build_number is not None else info.get("CFBundleVersion", "")),
        "minimum_system_version": minimum_system_version if minimum_system_version is not None else info.get("LSMinimumSystemVersion", ""),
        "sparkle_feed_url": info.get("SUFeedURL", ""),
        "sparkle_public_ed_key": info.get("SUPublicEDKey", ""),
        "release_channel": release_channel if release_channel is not None else info.get("CalouraReleaseChannel", ""),
        "requires_signed_entitlement": (
            requires_signed_entitlement
            if requires_signed_entitlement is not None
            else parse_bool(info.get("CalouraRequireSignedEntitlement"))
        ),
        "entitlement_service_url": (
            entitlement_service_url
            if entitlement_service_url is not None
            else info.get("CalouraLicenseEntitlementURL", "")
        ),
        "entitlement_public_key_configured": (
            entitlement_public_key_configured
            if entitlement_public_key_configured is not None
            else bool(str(info.get("CalouraLicenseEntitlementPublicKey", "")).strip())
        ),
        "app_path": app_path,
        "artifact_path": artifact_path,
        "sparkle_artifact_path": sparkle_artifact_path or artifact_path,
        "manual_download_artifact_path": manual_download_artifact_path,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a release manifest from an exported app bundle or source build settings.")
    parser.add_argument("--app", help="Path to Caloura.app")
    parser.add_argument("--info-plist", help="Path to source Info.plist")
    parser.add_argument("--output", required=True, help="Path to write the manifest JSON")
    parser.add_argument("--artifact", help="Optional packaged artifact path")
    parser.add_argument("--sparkle-artifact", help="Optional Sparkle update artifact path")
    parser.add_argument("--manual-artifact", help="Optional manual download artifact path")
    parser.add_argument("--bundle-identifier", help="Resolved bundle identifier")
    parser.add_argument("--marketing-version", help="Resolved marketing version")
    parser.add_argument("--build-number", help="Resolved build number")
    parser.add_argument("--minimum-system-version", help="Resolved minimum macOS version")
    parser.add_argument("--release-channel", help="Resolved release channel")
    parser.add_argument("--requires-signed-entitlement", help="Resolved signed-entitlement requirement")
    parser.add_argument("--entitlement-service-url", help="Resolved entitlement service URL")
    parser.add_argument(
        "--entitlement-public-key-configured",
        help="Resolved entitlement public key presence",
    )
    args = parser.parse_args()

    if bool(args.app) == bool(args.info_plist):
        raise SystemExit("Provide exactly one of --app or --info-plist")

    if args.app:
        app_path = Path(args.app)
        info_plist = app_path / "Contents" / "Info.plist"
        app_path_value = str(app_path)
    else:
        info_plist = Path(args.info_plist)
        app_path_value = ""

    if not info_plist.exists():
        raise SystemExit(f"Info.plist not found at {info_plist}")

    with info_plist.open("rb") as handle:
        info = plistlib.load(handle)

    manifest = build_manifest_from_info(
        info,
        app_path=app_path_value,
        artifact_path=str(Path(args.artifact)) if args.artifact else "",
        sparkle_artifact_path=(
            str(Path(args.sparkle_artifact))
            if args.sparkle_artifact else str(Path(args.artifact)) if args.artifact else ""
        ),
        manual_download_artifact_path=(
            str(Path(args.manual_artifact)) if args.manual_artifact else ""
        ),
        bundle_identifier=args.bundle_identifier,
        marketing_version=args.marketing_version,
        build_number=args.build_number,
        minimum_system_version=args.minimum_system_version,
        release_channel=args.release_channel,
        requires_signed_entitlement=(
            parse_bool(args.requires_signed_entitlement)
            if args.requires_signed_entitlement is not None else None
        ),
        entitlement_service_url=args.entitlement_service_url,
        entitlement_public_key_configured=(
            parse_bool(args.entitlement_public_key_configured)
            if args.entitlement_public_key_configured is not None else None
        ),
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8"
    )
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
