#!/usr/bin/env python3
"""Prints one version's section of CHANGELOG.md, for release notes.

Run with `python3 -I`. Usage: changelog-section.py <version> [CHANGELOG.md]
Fails when the file has no section for that version, or an empty one, so a
release cannot go out without notes.
"""
import os
import re
import sys


def section(text, version):
    """The body under `## [version]`, up to the next `## ` heading and link references."""
    pattern = re.compile(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |^\[[^\]]+\]: |\Z)", re.MULTILINE | re.DOTALL)
    match = pattern.search(text)
    return match.group(1).strip() if match else None


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "CHANGELOG.md")
    with open(path, encoding="utf-8") as changelog:
        body = section(changelog.read(), sys.argv[1])
    if not body:
        print(f"{path} has no notes for {sys.argv[1]}", file=sys.stderr)
        return 1
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
