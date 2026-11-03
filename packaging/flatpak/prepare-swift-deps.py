#!/usr/bin/env python3
# Runs inside the Flatpak build, which has no network. The Swift dependencies
# arrive as tarballs pinned by SHA-256 (swift-dependencies.json) in deps/<identity>.
# SwiftPM resolves from git, so each becomes a local git repository with the
# version tag or branch its pin names, is mirrored in place of its URL, and the
# pin's revision is rewritten to the local commit.
#
# usage: prepare-swift-deps.py <deps-dir> <package-dir>...
import json
import os
import re
import subprocess
import sys

GIT = ["git", "-c", "user.name=ycode-build", "-c", "user.email=build@invalid", "-c", "commit.gpgsign=false",
       "-c", "init.defaultBranch=ycode-pinned"]
ENV = dict(os.environ, GIT_AUTHOR_DATE="2000-01-01T00:00:00Z", GIT_COMMITTER_DATE="2000-01-01T00:00:00Z")


def git(cwd, *args):
    return subprocess.run(GIT + list(args), cwd=cwd, env=ENV, check=True, capture_output=True, text=True).stdout.strip()


def repository(path, state):
    git(path, "init", "-q")
    git(path, "add", "-A", "-f")
    git(path, "commit", "-q", "-m", "pinned source")
    if "version" in state:
        git(path, "tag", state["version"])
    if "branch" in state:
        git(path, "branch", state["branch"])
    return git(path, "rev-parse", "HEAD")


def main():
    deps = os.path.abspath(sys.argv[1])
    for package in sys.argv[2:]:
        resolved_path = os.path.join(package, "Package.resolved")
        with open(resolved_path) as f:
            resolved = json.load(f)
        resolved.pop("originHash", None)
        mirrors = []
        manifest_path = os.path.join(package, "Package.swift")
        with open(manifest_path) as f:
            manifest = f.read()
        for pin in resolved["pins"]:
            path = os.path.join(deps, pin["identity"])
            old = pin["state"]["revision"]
            new = repository(path, pin["state"])
            pin["state"]["revision"] = new
            manifest = manifest.replace(old, new)
            url = re.sub(r"\.git$", "", pin["location"])
            for original in (url, url + ".git"):
                mirrors.append({"mirror": path, "original": original})
        with open(resolved_path, "w") as f:
            json.dump(resolved, f, indent=2)
        with open(manifest_path, "w") as f:
            f.write(manifest)
        config = os.path.join(package, ".swiftpm", "configuration")
        os.makedirs(config, exist_ok=True)
        with open(os.path.join(config, "mirrors.json"), "w") as f:
            json.dump({"object": mirrors, "version": 1}, f, indent=2)


if __name__ == "__main__":
    main()
