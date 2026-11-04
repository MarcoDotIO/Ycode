#!/usr/bin/env python3
"""Checks that the Flatpak metainfo and CHANGELOG.md agree on a release.

Run with `python3 -I`. Usage:
    check-release-metadata.py <version> [CHANGELOG.md] [metainfo.xml]

Passes when the metainfo's newest `<release>` (the first one) has this version,
and its date is the date on CHANGELOG.md's `## [<version>] - <date>` heading.
Fails when either file has no entry, when the CHANGELOG heading has no date, or
when the two disagree, so a release cannot ship a metainfo that names another
version or day.
"""
import os
import re
import sys
import xml.etree.ElementTree as ElementTree

METAINFO = os.path.join("packaging", "flatpak", "io.github.MarcoDotIO.Ycode.metainfo.xml")


def changelog_date(text, version):
    """The date on the `## [version] - YYYY-MM-DD` heading, '' when it has none, None when absent."""
    heading = re.search(r"^## \[" + re.escape(version) + r"\](.*)$", text, re.MULTILINE)
    if not heading:
        return None
    date = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", heading.group(1))
    return date.group(1) if date else ""


def newest_release(path):
    """(version, date) of the first `<release>` in the metainfo, or None."""
    release = ElementTree.parse(path).getroot().find("releases/release")
    if release is None:
        return None
    return release.get("version"), release.get("date")


def problems(version, changelog_path, metainfo_path):
    """The first disagreement found, as a list of messages; empty when they agree."""
    with open(changelog_path, encoding="utf-8") as changelog:
        date = changelog_date(changelog.read(), version)
    if date is None:
        return [f"{changelog_path} has no `## [{version}]` section"]
    if not date:
        return [f"{changelog_path}: the `## [{version}]` heading has no date (`## [{version}] - YYYY-MM-DD`)"]
    newest = newest_release(metainfo_path)
    if newest is None:
        return [f"{metainfo_path} has no <release>"]
    if newest[0] != version:
        return [f"{metainfo_path}: the newest <release> is {newest[0]}, not {version}"]
    if newest[1] != date:
        return [f"{metainfo_path}: <release version=\"{version}\"> is dated {newest[1]}, "
                f"but {changelog_path} dates it {date}"]
    return []


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    changelog_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "CHANGELOG.md")
    metainfo_path = sys.argv[3] if len(sys.argv) > 3 else os.path.join(root, METAINFO)
    found = problems(sys.argv[1], changelog_path, metainfo_path)
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print(f"{sys.argv[1]}: CHANGELOG.md and the metainfo agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
