#!/usr/bin/env python3
"""Checks relative links and #anchors in the repository's public Markdown.

Run with `python3 -I`. It reads the root documents, .github/, docs/ and the
READMEs by default, or the files you name. External URLs are not fetched.
"""
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LINK = re.compile(r"(?<!\\)\[(?:[^\]\\]|\\.)*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)|(?:src|href)=\"([^\"]+)\"")
FENCE = re.compile(r"^\s*(```|~~~)")


def default_files():
    """Root documents, community files, docs and the area READMEs."""
    patterns = ["*.md", ".github/*.md", ".github/ISSUE_TEMPLATE/*.md", "docs/*.md",
                "ycode/README.md", "frameworks/README.md", "composer/README.md", "packaging/README.md"]
    found = []
    for pattern in patterns:
        found += glob.glob(os.path.join(REPO, pattern))
    return sorted(set(found))


def anchors(path):
    """GitHub's heading anchors for a Markdown file."""
    names = set()
    fenced = False
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            if FENCE.match(line):
                fenced = not fenced
            if fenced or not line.startswith("#"):
                continue
            title = re.sub(r"[`*_]|\[|\]\([^)]*\)", "", line.lstrip("#").strip())
            slug = re.sub(r"[^\w\- ]", "", title.lower()).replace(" ", "-")
            base, count = slug, 0
            while slug in names:
                count += 1
                slug = f"{base}-{count}"
            names.add(slug)
    return names


def check(path):
    """Returns the broken links in one file."""
    broken = []
    fenced = False
    with open(path, encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            if FENCE.match(line):
                fenced = not fenced
            if fenced:
                continue
            for match in LINK.finditer(re.sub(r"`[^`]*`", "", line)):
                target = match.group(1) or match.group(2)
                if re.match(r"[a-z][a-z0-9+.-]*:", target):
                    continue
                file_part, _, anchor = target.partition("#")
                full = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) if file_part else path
                if not os.path.exists(full):
                    broken.append((number, target, "no such file"))
                elif anchor and full.endswith(".md") and anchor.lower() not in anchors(full):
                    broken.append((number, target, "no such heading"))
    return broken


def main():
    files = [os.path.abspath(name) for name in sys.argv[1:]] or default_files()
    total = 0
    for path in files:
        for number, target, why in check(path):
            print(f"{os.path.relpath(path, REPO)}:{number}: {target}: {why}")
            total += 1
    print(f"Checked {len(files)} files: {total} broken links.")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
