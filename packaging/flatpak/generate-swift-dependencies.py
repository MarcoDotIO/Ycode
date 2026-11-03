#!/usr/bin/env python3
# Regenerates swift-dependencies.json from ycode/Package.resolved and
# ycode/Tools/ycode-swb/Package.resolved: one tarball per pin, by commit, with the
# SHA-256 of what was downloaded now. Run it when a Package.resolved changes.
#
# usage: python3 -I packaging/flatpak/generate-swift-dependencies.py
import hashlib
import json
import os
import re
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PACKAGES = ["ycode/Package.resolved", "ycode/Tools/ycode-swb/Package.resolved"]


def main():
    try:
        with open(os.path.join(HERE, "swift-dependencies.json")) as f:
            known = {s["url"]: s["sha256"] for s in json.load(f)}
    except FileNotFoundError:
        known = {}
    sources = {}
    for resolved in PACKAGES:
        with open(os.path.join(ROOT, resolved)) as f:
            pins = json.load(f)["pins"]
        for pin in pins:
            base = re.sub(r"\.git$", "", pin["location"])
            url = "%s/archive/%s.tar.gz" % (base, pin["state"]["revision"])
            dest = "deps/" + pin["identity"]
            if dest in sources and sources[dest]["url"] != url:
                raise SystemExit("two revisions of " + pin["identity"])
            sha = known.get(url)
            if sha is None:
                print("downloading", url)
                with urllib.request.urlopen(url) as r:
                    sha = hashlib.sha256(r.read()).hexdigest()
            sources[dest] = {"type": "archive", "url": url, "sha256": sha, "dest": dest}
    with open(os.path.join(HERE, "swift-dependencies.json"), "w") as f:
        json.dump([sources[k] for k in sorted(sources)], f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
