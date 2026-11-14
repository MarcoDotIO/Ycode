#!/usr/bin/env python3
"""Write the navigator-icons test project: GlassScroll (make-test-project.py)
with three more file types in its synchronized GlassScroll folder, so the
project navigator shows Swift, Python, JSON and Markdown rows together.

The copy is written to OUT_DIR/icons/GlassScroll (its own folder, so the
extra files never leak into the plain GlassScroll copy that the other
council sessions regenerate in OUT_DIR/GlassScroll). All content is our own.

Usage: python3 -I make-icons-project.py OUT_DIR   (writes OUT_DIR/icons/GlassScroll)
"""

import importlib.util
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent

PYTHON = '''"""convert.py: a helper script in the test project (navigator icon capture)."""


def scale(values, factor):
    return [v * factor for v in values]


if __name__ == "__main__":
    print(scale([1, 2, 3], 2))
'''

JSON = '''{
  "name": "GlassScroll palette",
  "colors": ["#1E6FD9", "#F2A900", "#2BB673"],
  "version": 1
}
'''

MARKDOWN = '''# Notes

Test project for the navigator icon capture.

- Swift sources
- a Python helper
- a JSON palette
'''


def write(out_dir: pathlib.Path) -> pathlib.Path:
    spec = importlib.util.spec_from_file_location("make_test_project", HERE / "make-test-project.py")
    glass = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(glass)
    parent = out_dir / "icons"
    if parent.exists():
        shutil.rmtree(parent)
    parent.mkdir(parents=True)
    project = glass.write(parent)
    sources = parent / glass.NAME / glass.NAME
    (sources / "convert.py").write_text(PYTHON)
    (sources / "palette.json").write_text(JSON)
    (sources / "NOTES.md").write_text(MARKDOWN)
    return project


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print(write(pathlib.Path(sys.argv[1])))
