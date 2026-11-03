"""Regenerates the OpenUSD-written test fixtures from our hand-written ones.

Needs Pixar's usd-core from PyPI (OpenUSD, Tomorrow Open Source Technology
License 1.0). Run from this directory:

    python3 -m venv /tmp/usdenv && /tmp/usdenv/bin/pip install usd-core
    /tmp/usdenv/bin/python -I Scripts/make_fixtures.py

Outputs (all derived from our own files, so they carry this repository's
licence):
  Tests/USDCoreTests/Fixtures/scene.canonical.usda  OpenUSD's text output
  Tests/USDCoreTests/Fixtures/scene.usdc            OpenUSD's crate output
  Tests/USDCoreTests/Fixtures/props.usdz            OpenUSD's USDZ package
"""
import os
import sys

from pxr import Sdf, UsdUtils

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "USDCoreTests", "Fixtures")
os.chdir(here)
scene = Sdf.Layer.FindOrOpen("scene.usda")
if scene is None:
    sys.exit("cannot open scene.usda")
scene.Export("scene.canonical.usda")
scene.Export("scene.usdc")
if not UsdUtils.CreateNewUsdzPackage("props.usda", "props.usdz"):
    sys.exit("cannot package props.usda")
print("fixtures written to", here)
