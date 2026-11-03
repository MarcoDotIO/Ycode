#!/usr/bin/env python3
"""Fails when a tracked file holds something that must not be public.

Run with `python3 -I` from anywhere in the repository. It looks at the files
git tracks and reports private addresses, personal home folders, mail
addresses, access tokens, private keys, and files that must never be committed
(Apple firmware, signing identities, local state, anything oversize).

Only generic patterns live here. To also check for real names, keep them in a
file outside the repository, one regular expression per line, and pass
`--extra-patterns FILE`. Known exceptions are in .github/ci/scan-allowlist.txt.
"""
import argparse
import fnmatch
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOWLIST = os.path.join(REPO, ".github", "ci", "scan-allowlist.txt")
MAX_BYTES = 3 * 1024 * 1024

# Placeholder names that tests and docs use in example paths.
PLACEHOLDER_USERS = r"(?:me|you|u|x|user|username|name|tester|test|someone|runner|example|<[^>]*>|\$[A-Za-z_{(]+.*)"

PATTERNS = [
    ("private IPv4 address",
     r"(?<![\d.])(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})(?![\d.])"),
    ("home folder of a real user", r"/(?:Users|home)/(?!" + PLACEHOLDER_USERS + r"(?:/|\b))[A-Za-z][A-Za-z0-9._-]+/"),
    ("removable volume path", r"/(?:Volumes|media|mnt)/(?!" + PLACEHOLDER_USERS + r"(?:/|\b))[A-Za-z0-9][A-Za-z0-9._ -]+/"),
    # `.local` and friends only where a host is expected: `context.local` is ordinary code.
    ("private host name",
     r"(?:(?:https?|ssh|rsync|ftp)://|@|\bHost(?:Name)?\s+)[A-Za-z0-9][A-Za-z0-9.-]*\.(?:local|lan|internal|intranet|corp)(?![A-Za-z0-9_.-])"
     r"|\b(?:[a-z0-9-]+\.)+edu(?![A-Za-z0-9_-])"),
    ("ssh login",
     r"\bssh\s+(?:-\S+\s+(?:\S+\s+)?)*(?!<)[a-z_][a-z0-9_-]*@[A-Za-z0-9][A-Za-z0-9.-]*"),
    # Not `name@2x.png`, and not the reserved example domains.
    ("mail address",
     r"(?i)\b[A-Za-z0-9._%+-]+@(?!(?:[a-z0-9-]+\.)*(?:example|test|invalid)\b|example\.(?:com|org|net)\b"
     r"|users\.noreply\.github\.com\b|noreply\.github\.com\b|anthropic\.com\b|github\.com\b)"
     r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?!png\b|jpe?g\b|ktx\b|pdf\b|heic\b|svg\b|tiff?\b|gif\b|astc\b)[A-Za-z]{2,}\b"),
    ("GitHub token", r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b"),
    ("cloud or service key", r"\b(?:AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{32,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})\b"),
    ("private key", r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
]

FORBIDDEN_FILES = [
    ("local state", ["*.DS_Store", ".drive-origin", "*.xcuserstate", "*/xcuserdata/*", ".claude/*", "*.swp"]),
    ("secrets", [".env", "*/.env", ".env.*", "*/.env.*", "*.p12", "*.p8", "*.mobileprovision", "*.keychain*"]),
    ("Apple firmware or runtime", ["*.ipsw", "*.im4p", "*.img4", "*.simruntime/*", "*.aea", "*.xip"]),
    ("disassembler project", ["*.gpr", "*.rep/*", "research/dirty/*"]),
    ("build output", ["*/.build/*", "*/.build-*/*", "*/DerivedData/*"]),
]


def tracked_files():
    """Paths git tracks, relative to the repository root."""
    output = subprocess.run(["git", "ls-files", "-z"], cwd=REPO, check=True, capture_output=True).stdout
    return [path for path in output.decode("utf-8", "surrogateescape").split("\0") if path]


def load_allowlist(path):
    """Returns (glob, compiled regex) pairs. Lines are `glob<space>regex`; no regex allows the whole file."""
    rules = []
    if not os.path.exists(path):
        return rules
    with open(path, encoding="utf-8") as listing:
        for line in listing:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            pattern, _, regex = line.strip().partition(" ")
            rules.append((pattern, re.compile(regex.strip()) if regex.strip() else None))
    return rules


def allowed(path, match_text, rules):
    """True when an allowlist line covers this finding."""
    for pattern, regex in rules:
        if fnmatch.fnmatch(path, pattern) and (regex is None or regex.search(match_text)):
            return True
    return False


def scan(paths, patterns, rules):
    """Returns findings as (path, line number, kind, text)."""
    findings = []
    for path in paths:
        full = os.path.join(REPO, path)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        for kind, globs in FORBIDDEN_FILES:
            if any(fnmatch.fnmatch(path, item) for item in globs):
                findings.append((path, 0, kind, "this file must not be committed"))
        size = os.path.getsize(full)
        if size > MAX_BYTES and not allowed(path, "oversize", rules):
            findings.append((path, 0, "oversize file", f"{size / 1024 / 1024:.1f} MiB; the limit is {MAX_BYTES // 1024 // 1024} MiB"))
        with open(full, "rb") as stream:
            data = stream.read()
        if b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", "replace")
        for number, line in enumerate(text.splitlines(), 1):
            for kind, regex in patterns:
                for match in regex.finditer(line):
                    if not allowed(path, match.group(0), rules):
                        findings.append((path, number, kind, match.group(0)))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extra-patterns", help="file of more regular expressions, one per line, kept outside the repository")
    parser.add_argument("--list-all", action="store_true", help="ignore the allowlist")
    parser.add_argument("paths", nargs="*", help="only these tracked files")
    options = parser.parse_args()

    patterns = [(kind, re.compile(regex)) for kind, regex in PATTERNS]
    if options.extra_patterns:
        with open(options.extra_patterns, encoding="utf-8") as extra:
            patterns += [("extra pattern", re.compile(line.strip(), re.IGNORECASE)) for line in extra if line.strip()]
    rules = [] if options.list_all else load_allowlist(ALLOWLIST)
    paths = options.paths or tracked_files()

    findings = scan(paths, patterns, rules)
    for path, number, kind, text in findings:
        # Say where and what kind, and only the first characters: a log must not republish a secret.
        shown = text if kind not in ("GitHub token", "cloud or service key") else text[:6] + "…"
        print(f"{path}:{number}: {kind}: {shown}")
        if os.environ.get("GITHUB_ACTIONS"):
            print(f"::error file={path},line={max(number, 1)},title=Public scan::{kind}")
    print(f"Scanned {len(paths)} tracked files: {len(findings)} findings.")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
