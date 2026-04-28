#!/usr/bin/env python3
"""Regression tests for the appcast no-downgrade gate.

Run with: `python3 -m pytest scripts/tests/test_validate_appcast_downgrade.py`
or `python3 scripts/tests/test_validate_appcast_downgrade.py` for direct invocation.
"""
from __future__ import annotations

import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))

# Importing the validator runs no top-level work beyond defining helpers.
import validate_appcast_against_manifest as validator  # noqa: E402


def make_appcast(builds: list[int]) -> ET.Element:
    """Construct a minimal appcast root with one <item> per build number.

    The first entry in `builds` becomes the candidate update (item[0]),
    matching how publish.sh inserts the newest item at the top.
    """
    rss = ET.Element("rss")
    channel = ET.SubElement(rss, "channel")
    for build in builds:
        item = ET.SubElement(channel, "item")
        enclosure = ET.SubElement(item, "enclosure")
        enclosure.set(f"{{{validator.SPARKLE_NAMESPACE}}}version", str(build))
    return rss


class DowngradeDetectionTests(unittest.TestCase):

    def test_monotonic_descending_order_passes(self) -> None:
        # Realistic appcast: newest item first, oldest last.
        rss = make_appcast([20260417000000, 20260408000000, 20260301000000])
        items = validator.all_items(rss)
        self.assertIsNone(validator.detect_downgrade(items))

    def test_single_item_passes(self) -> None:
        rss = make_appcast([20260417000000])
        items = validator.all_items(rss)
        self.assertIsNone(validator.detect_downgrade(items))

    def test_empty_appcast_fails(self) -> None:
        rss = make_appcast([])
        items = validator.all_items(rss)
        result = validator.detect_downgrade(items)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertIn("no <item>", result)

    def test_planted_older_first_item_fails(self) -> None:
        # Attack pattern: replace newest item with an older signed copy.
        rss = make_appcast([20260301000000, 20260417000000])
        items = validator.all_items(rss)
        result = validator.detect_downgrade(items)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertIn("downgrade detected", result)
        self.assertIn("20260301000000", result)
        self.assertIn("20260417000000", result)

    def test_equal_versions_pass(self) -> None:
        # Edge: two items at the same build are odd but not a downgrade
        # (Sparkle won't update sideways). The publish-side gate is the
        # one that prevents same-version re-publication; the structural
        # gate here only blocks higher subsequent items.
        rss = make_appcast([20260417000000, 20260417000000])
        items = validator.all_items(rss)
        self.assertIsNone(validator.detect_downgrade(items))

    def test_parse_build_number_from_sibling_tag(self) -> None:
        # Some hand-edited appcasts put sparkle:version on a sibling tag
        # rather than on the enclosure. Both must work.
        rss = ET.Element("rss")
        channel = ET.SubElement(rss, "channel")
        item = ET.SubElement(channel, "item")
        sib = ET.SubElement(
            item, f"{{{validator.SPARKLE_NAMESPACE}}}version"
        )
        sib.text = "20260417000000"
        ET.SubElement(item, "enclosure")
        self.assertEqual(validator.parse_build_number(item), 20260417000000)

    def test_parse_build_number_missing_raises(self) -> None:
        rss = ET.Element("rss")
        channel = ET.SubElement(rss, "channel")
        item = ET.SubElement(channel, "item")
        with self.assertRaises(SystemExit):
            validator.parse_build_number(item)


class MinimumAutoupdateVersionTests(unittest.TestCase):

    def test_appcast_without_autoupdate_floor_passes(self) -> None:
        rss = make_appcast([20260417000000, 20260408000000])
        items = validator.all_items(rss)
        self.assertIsNone(validator.detect_minimum_autoupdate_version(items))

    def test_appcast_with_autoupdate_floor_fails(self) -> None:
        rss = make_appcast([20260417000000, 20260408000000])
        items = validator.all_items(rss)
        floor = ET.SubElement(
            items[0], f"{{{validator.SPARKLE_NAMESPACE}}}minimumAutoupdateVersion"
        )
        floor.text = "20260408000000"

        result = validator.detect_minimum_autoupdate_version(items)

        self.assertIsNotNone(result)
        assert result is not None
        self.assertIn("minimumAutoupdateVersion detected", result)
        self.assertIn("20260408000000", result)


if __name__ == "__main__":
    unittest.main()
