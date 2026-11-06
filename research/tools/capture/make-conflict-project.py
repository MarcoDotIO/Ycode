#!/usr/bin/env python3
"""Write the conflict test project, Merger: a git repository with a branch
that conflicts with main in one Swift file.

Merger is the GlassScroll project (make-test-project.py) renamed and cut
down to its app files and the plain group, in a git repository:

- main and feature both start from one commit;
- feature then changes two places in Greeting.swift (and adds a line that
  does not conflict), main changes the same two places differently;
- main is checked out and clean, so merging feature into main from the
  app's own menu stops on two conflicts in Greeting.swift.

The commits use a fixed test identity and fixed dates, so the history shows
no one's name and every session opens identical input.

Usage: python3 -I make-conflict-project.py OUT_DIR   (writes OUT_DIR/Merger)
"""

import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
NAME = "Merger"

BASE = """// Greeting.swift: material for the conflict editor captures.

import Foundation

struct Greeting {
    let name: String

    func text() -> String {
        "Hello, \\(name)!"
    }

    func farewell() -> String {
        "Goodbye, \\(name)."
    }

    static let defaultName = "World"
}
"""

FEATURE = """// Greeting.swift: material for the conflict editor captures.

import Foundation

struct Greeting {
    let name: String

    func text() -> String {
        "Welcome aboard, \\(name)!"
    }

    func farewell() -> String {
        "See you soon, \\(name)."
    }

    static let defaultName = "World"
    static let punctuation = "!"
}
"""

MAIN = """// Greeting.swift: material for the conflict editor captures.

import Foundation

struct Greeting {
    let name: String

    func text() -> String {
        "Good morning, \\(name)!"
    }

    func farewell() -> String {
        "Farewell, \\(name)."
    }

    static let defaultName = "World"
}
"""

IDENTITY = {
    "GIT_AUTHOR_NAME": "Capture Test", "GIT_AUTHOR_EMAIL": "capture@example.invalid",
    "GIT_COMMITTER_NAME": "Capture Test", "GIT_COMMITTER_EMAIL": "capture@example.invalid",
}


def load_glass_scroll():
    spec = importlib.util.spec_from_file_location("make_test_project", HERE / "make-test-project.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root, *args, date="2026-01-01T12:00:00Z"):
    env = {**os.environ, **IDENTITY, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
           "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    subprocess.run(["git", *args], cwd=root, env=env, check=True, capture_output=True)


def write(out_dir: pathlib.Path) -> pathlib.Path:
    root = out_dir / NAME
    if root.exists():
        shutil.rmtree(root)
    glass = load_glass_scroll()
    glass.NAME = NAME
    glass.write(out_dir)
    sources = root / NAME
    for extra in ("Long.swift", "Bands.swift", "Stripes.png"):
        (sources / extra).unlink()
    shutil.rmtree(sources / "Models")
    greeting = sources / "Greeting.swift"
    greeting.write_text(BASE)
    (root / ".gitignore").write_text("xcuserdata/\n*.xcuserstate\nproject.xcworkspace/\nDerivedData/\n")
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "Start Merger")
    git(root, "branch", "feature")
    git(root, "checkout", "-q", "feature")
    greeting.write_text(FEATURE)
    git(root, "commit", "-q", "-am", "Friendlier greetings", date="2026-01-02T12:00:00Z")
    git(root, "checkout", "-q", "main")
    greeting.write_text(MAIN)
    git(root, "commit", "-q", "-am", "Time-of-day greetings", date="2026-01-03T12:00:00Z")
    return root / f"{NAME}.xcodeproj"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print(write(pathlib.Path(sys.argv[1])))
